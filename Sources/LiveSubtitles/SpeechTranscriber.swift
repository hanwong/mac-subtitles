import CoreMedia
import Foundation
import Speech

/// Continuous speech-to-text over a stream of audio buffers.
///
/// SFSpeechRecognizer works per utterance, so the audio is cut into segments: a segment ends on a
/// pause in speech or when it gets too long, and a new recognition task takes over immediately.
/// `append` may be called from any thread; everything else, including callbacks, runs on the main thread.
final class SpeechTranscriber: @unchecked Sendable {
    /// Text of the segment in progress (grows as more is recognized).
    var onPartial: ((String) -> Void)?
    /// Final text of a finished segment.
    var onFinal: ((String) -> Void)?

    private static let pauseToEndSegment: TimeInterval = 1.0
    private static let maxSegmentDuration: TimeInterval = 15
    /// Server-based recognition is limited to about a minute per task, so recycle idle tasks too.
    private static let maxIdleDuration: TimeInterval = 45

    private let recognizer: SFSpeechRecognizer
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?  // guarded by `lock`

    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var text = ""
    private var lastChange = Date()
    private var segmentStart = Date()
    private var timer: Timer?
    private var running = false

    init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
    }

    func start() {
        running = true
        startSegment()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        endSegment()
    }

    func append(_ buffer: CMSampleBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.appendAudioSampleBuffer(buffer)
    }

    private func startSegment() {
        generation += 1
        let generation = generation
        text = ""
        segmentStart = Date()
        lastChange = segmentStart

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let ended = error != nil || result?.isFinal == true
            DispatchQueue.main.async {
                self?.handle(generation: generation, text: text, ended: ended)
            }
        }
        lock.lock()
        self.request = request
        lock.unlock()
    }

    private func endSegment() {
        lock.lock()
        let request = self.request
        self.request = nil
        lock.unlock()
        request?.endAudio()
        task?.finish()
        task = nil
        if !text.isEmpty { onFinal?(text) }
        text = ""
    }

    private func handle(generation: Int, text newText: String?, ended: Bool) {
        // Late results from a segment that was already rotated out are dropped.
        guard running, generation == self.generation else { return }
        if let newText, !newText.isEmpty, newText != text {
            text = newText
            lastChange = Date()
            onPartial?(newText)
        }
        guard ended else { return }
        let age = Date().timeIntervalSince(segmentStart)
        endSegment()
        if age < 0.5 {
            // The task died right away (e.g. recognizer unavailable); don't spin.
            self.generation += 1
            let expected = self.generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.running, self.generation == expected else { return }
                self.startSegment()
            }
        } else {
            startSegment()
        }
    }

    private func tick() {
        guard running, task != nil else { return }
        let now = Date()
        let shouldRotate: Bool
        if text.isEmpty {
            shouldRotate = now.timeIntervalSince(segmentStart) > Self.maxIdleDuration
        } else {
            shouldRotate = now.timeIntervalSince(lastChange) > Self.pauseToEndSegment
                || now.timeIntervalSince(segmentStart) > Self.maxSegmentDuration
        }
        if shouldRotate {
            endSegment()
            startSegment()
        }
    }
}
