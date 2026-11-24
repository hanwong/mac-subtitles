import AVFoundation
import Foundation
import WhisperKit

/// Listens to the microphone and reports each thing that was said, as text.
///
/// The microphone signal is cut into utterances at pauses; only those are sent to Whisper, so the model
/// is idle while nobody speaks. Callbacks arrive on the main thread.
final class SpeechListener: @unchecked Sendable {
    var onUtterance: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private static let sampleRate = 16_000
    /// Loudness is judged in 0.1 s frames.
    private static let frameLength = sampleRate / 10
    private static let minThreshold: Float = 0.008
    /// Speech has to be this many times louder than the room's background noise.
    private static let noiseMargin: Float = 3
    private static let pauseFrames = 7
    private static let minSpeechFrames = 4
    private static let maxFrames = 80
    private static let maxNoSpeechProbability: Float = 0.5
    private static let minAverageLogProbability: Float = -0.9
    private static let leadInFrames = 5

    private let whisper: WhisperKit
    private let options: DecodingOptions
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var utterances: AsyncStream<[Float]>.Continuation?
    private var task: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    // Segmentation state; only touched from the audio thread.
    private var pending: [Float] = []
    private var leadIn: [Float] = []
    private var utterance: [Float] = []
    private var speaking = false
    private var speechFrames = 0
    private var quietFrames = 0
    private var noiseFloor: Float = 0.002

    /// - Parameter language: Whisper language code the commands are spoken in.
    init(whisper: WhisperKit, language: String) {
        self.whisper = whisper
        // No timestamps and a single retry: commands are short, and a quick answer matters more.
        // Deliberately no prompt with the wake word in it: on noise, Whisper tends to "hear" its own prompt.
        options = DecodingOptions(
            language: language, temperatureFallbackCount: 1, skipSpecialTokens: true, withoutTimestamps: true)
    }

    func start() throws {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(2))
        utterances = continuation
        task = Task { [weak self] in
            for await samples in stream { await self?.transcribe(samples) }
        }
        // The input device can change under us (AirPods connecting, a display with a mic unplugged).
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            do { try self.startEngine() } catch { self.onError?(error.localizedDescription) }
        }
        try startEngine()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        utterances?.finish()
        utterances = nil
        task?.cancel()
        task = nil
    }

    private func startEngine() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()

        // Echo cancellation: macOS subtracts whatever the Mac itself is playing from the microphone signal,
        // so a video or music coming out of the speakers isn't heard as speech.
        if !input.isVoiceProcessingEnabled {
            try? input.setVoiceProcessingEnabled(true)
        }
        if input.isVoiceProcessingEnabled {
            // Voice processing turns other apps' audio down by default, as in a call. Keep that to a minimum.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.sampleRate), channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw NSError(
                domain: "HeyMac", code: 1, userInfo: [NSLocalizedDescriptionKey: "사용할 수 있는 마이크가 없습니다."])
        }
        // With voice processing the microphone array can show up as several channels; the first is the processed voice.
        if inputFormat.channelCount > 1 { converter.channelMap = [0] }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer, to: outputFormat)
        }
        engine.prepare()
        try engine.start()
    }

    // MARK: Audio thread

    private func process(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) {
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = converted.floatChannelData?[0] else { return }

        pending.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
        while pending.count >= Self.frameLength {
            consume(frame: Array(pending.prefix(Self.frameLength)))
            pending.removeFirst(Self.frameLength)
        }
    }

    private func consume(frame: [Float]) {
        let loudness = (frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)).squareRoot()
        let isSpeech = loudness > max(Self.minThreshold, noiseFloor * Self.noiseMargin)

        guard speaking else {
            if isSpeech {
                // Include the moment before, so the first syllable isn't clipped.
                speaking = true
                utterance = leadIn + frame
                speechFrames = 1
                quietFrames = 0
            } else {
                noiseFloor = noiseFloor * 0.95 + loudness * 0.05
                leadIn = Array((leadIn + frame).suffix(Self.leadInFrames * Self.frameLength))
            }
            return
        }

        utterance.append(contentsOf: frame)
        if isSpeech {
            speechFrames += 1
            quietFrames = 0
        } else {
            quietFrames += 1
        }
        guard quietFrames >= Self.pauseFrames || utterance.count >= Self.maxFrames * Self.frameLength else { return }

        // Anything shorter is a click or a cough, not a command.
        if speechFrames >= Self.minSpeechFrames { utterances?.yield(utterance) }
        speaking = false
        utterance = []
        leadIn = []
    }

    // MARK: Recognition

    private func transcribe(_ samples: [Float]) async {
        do {
            let result = try await whisper.transcribe(audioArray: Self.normalized(samples), decodeOptions: options)
                .first
            // Whisper writes something even for a cough or a door closing. Its own confidence figures tell
            // those guesses from real speech; a doubtful result is dropped rather than acted on.
            let segments = result?.segments ?? []
            let confident = !segments.isEmpty && segments.allSatisfy {
                $0.noSpeechProb < Self.maxNoSpeechProbability && $0.avgLogprob > Self.minAverageLogProbability
            }
            let text = confident ? Self.clean(result?.text ?? "") : ""
            guard !text.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in self?.onUtterance?(text) }
        } catch {
            if Task.isCancelled { return }
            let message = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.onError?(message) }
        }
    }

    /// Brings quiet speech up to a level Whisper hears well. The gain is capped, and faint sounds are left
    /// alone, so that background noise isn't blown up into something that sounds like words.
    private static func normalized(_ samples: [Float]) -> [Float] {
        let peak = samples.reduce(0) { max($0, abs($1)) }
        guard peak > 0.02 else { return samples }
        let gain = min(0.9 / peak, 8)
        return samples.map { $0 * gain }
    }

    /// Strips leftover control tokens and drops non-speech annotations such as "[Music]".
    private static func clean(_ text: String) -> String {
        let text = text
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isAnnotation = text.range(of: "^[\\[(（【♪*].*[\\])）】♪*]$", options: .regularExpression) != nil
        let hasWords = text.contains { $0.isLetter || $0.isNumber }
        return isAnnotation || !hasWords ? "" : text
    }
}
