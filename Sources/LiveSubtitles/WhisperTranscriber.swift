import Foundation
import WhisperKit

/// Continuous speech-to-text with Whisper.
///
/// Audio accumulates until the speaker pauses (or a length limit is hit), then that stretch is transcribed
/// in one go. Each result is a finished piece of speech, in whatever language was spoken.
/// `append` may be called from any thread; callbacks arrive on the main thread.
/// How eagerly speech is cut into pieces: shorter pieces appear sooner but give Whisper less context.
enum SubtitlePace: String, CaseIterable, Identifiable {
    case fast, balanced, accurate

    var id: String { rawValue }

    var name: String {
        switch self {
        case .fast: return "빠르게"
        case .balanced: return "보통"
        case .accurate: return "정확하게"
        }
    }

    fileprivate struct Timing {
        /// Seconds of quiet that end an utterance.
        let pause: Double
        /// The shorter pause accepted once an utterance has run for `longUtterance` seconds.
        let shortPause: Double
        let longUtterance: Double
        /// Speech that never pauses is cut after this many seconds.
        let maxUtterance: Double
    }

    fileprivate var timing: Timing {
        switch self {
        case .fast: return Timing(pause: 0.3, shortPause: 0.2, longUtterance: 2, maxUtterance: 4)
        case .balanced: return Timing(pause: 0.4, shortPause: 0.2, longUtterance: 3, maxUtterance: 7)
        case .accurate: return Timing(pause: 0.6, shortPause: 0.3, longUtterance: 5, maxUtterance: 10)
        }
    }
}

final class WhisperTranscriber: @unchecked Sendable {
    struct Utterance {
        let text: String
        /// Whisper language code ("en", "ja", ...): detected, or the one that was requested.
        let language: String
    }

    var onUtterance: ((Utterance) -> Void)?
    var onError: ((String) -> Void)?

    private static let sampleRate = AudioCapture.sampleRate
    /// Loudness is judged in 0.1 s frames.
    private static let frameLength = sampleRate / 10
    private static let speechThreshold: Float = 0.005
    private static let minSpeechFrames = 3
    private static let leadInFrames = 2

    private let whisper: WhisperKit
    private let options: DecodingOptions
    private let pauseFrames: Int
    private let shortPauseFrames: Int
    private let longUtterance: Int
    private let maxUtterance: Int
    private let lock = NSLock()
    private var samples: [Float] = []  // guarded by `lock`
    private var task: Task<Void, Never>?

    /// - Parameter language: Whisper language code, or nil to detect it for every utterance.
    init(whisper: WhisperKit, language: String?, pace: SubtitlePace) {
        self.whisper = whisper
        // One retry at a higher temperature instead of the default five keeps hard passages from stalling.
        options = DecodingOptions(
            language: language, temperatureFallbackCount: 1, detectLanguage: language == nil, skipSpecialTokens: true)
        let timing = pace.timing
        let framesPerSecond = Double(Self.sampleRate / Self.frameLength)
        pauseFrames = Int((timing.pause * framesPerSecond).rounded())
        shortPauseFrames = Int((timing.shortPause * framesPerSecond).rounded())
        longUtterance = Int(timing.longUtterance * Double(Self.sampleRate))
        maxUtterance = Int(timing.maxUtterance * Double(Self.sampleRate))
    }

    func start() {
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func append(_ newSamples: [Float]) {
        lock.lock()
        samples.append(contentsOf: newSamples)
        lock.unlock()
    }

    private struct Chunk {
        let samples: [Float]
        /// Cut at the length limit rather than at a pause; its samples are still in the buffer.
        let forced: Bool
    }

    private func run() async {
        while !Task.isCancelled {
            guard let chunk = nextChunk() else {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            var consumed = chunk.samples.count
            do {
                let result = try await whisper.transcribe(audioArray: chunk.samples, decodeOptions: options).first
                var segments = result?.segments ?? []
                // A forced cut usually lands mid-sentence. Hold back the last segment's audio so it is
                // transcribed again, complete, together with what follows.
                if chunk.forced, segments.count >= 2, let last = segments.last {
                    let keepFrom = Int(last.start * Float(Self.sampleRate))
                    if keepFrom > Self.sampleRate, keepFrom < consumed {
                        consumed = keepFrom
                        segments.removeLast()
                    }
                }
                let text = Self.clean(segments.map(\.text).joined())
                if !text.isEmpty, !Task.isCancelled {
                    let utterance = Utterance(text: text, language: options.language ?? result?.language ?? "en")
                    DispatchQueue.main.async { [weak self] in self?.onUtterance?(utterance) }
                }
            } catch {
                if Task.isCancelled { break }
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in self?.onError?(message) }
            }
            if chunk.forced {
                lock.lock()
                samples.removeFirst(min(consumed, samples.count))
                lock.unlock()
            }
        }
    }

    /// The next stretch of audio that is ready to transcribe, if any.
    private func nextChunk() -> Chunk? {
        lock.lock()
        defer { lock.unlock() }

        var frames = stride(from: 0, to: samples.count - Self.frameLength + 1, by: Self.frameLength).map { start in
            var sum: Float = 0
            for index in start..<start + Self.frameLength { sum += samples[index] * samples[index] }
            return (sum / Float(Self.frameLength)).squareRoot() > Self.speechThreshold
        }
        guard let firstSpeech = frames.firstIndex(of: true) else {
            // Only silence so far: keep just enough that the start of the next word isn't clipped.
            let keep = Self.leadInFrames * Self.frameLength
            if samples.count > keep { samples.removeFirst(samples.count - keep) }
            return nil
        }
        let leadingSilence = max(0, firstSpeech - Self.leadInFrames)
        samples.removeFirst(leadingSilence * Self.frameLength)
        frames.removeFirst(leadingSilence)

        let trailingSilence = frames.reversed().prefix { !$0 }.count
        let neededPause = samples.count > longUtterance ? shortPauseFrames : pauseFrames
        if trailingSilence >= neededPause {
            let chunk = samples
            samples.removeAll(keepingCapacity: true)
            // A click or a pop, not speech.
            guard frames.filter({ $0 }).count >= Self.minSpeechFrames else { return nil }
            return Chunk(samples: chunk, forced: false)
        }
        if samples.count >= maxUtterance {
            return Chunk(samples: samples, forced: true)
        }
        return nil
    }

    /// Strips leftover control tokens and drops non-speech annotations such as "[Music]" or "♪".
    private static func clean(_ text: String) -> String {
        let text = text
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isAnnotation = text.range(of: "^[\\[(（【♪*].*[\\])）】♪*]$", options: .regularExpression) != nil
        let hasWords = text.contains { $0.isLetter || $0.isNumber }
        return isAnnotation || !hasWords ? "" : text
    }
}
