import CoreMedia
import Foundation
import ScreenCaptureKit

enum AudioCaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "캡처할 디스플레이를 찾지 못했습니다."
        }
    }
}

/// Captures all system audio output (every app except this one) via ScreenCaptureKit.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Called on a background queue with each batch of samples (mono, `sampleRate` Hz, -1...1).
    var onAudio: (([Float]) -> Void)?
    /// Called on a background queue about twice a second with the loudest sample (0...1) since the last call.
    var onLevel: ((Float) -> Void)?
    /// Called on a background queue when the stream stops unexpectedly.
    var onStop: ((Error) -> Void)?

    /// The rate Whisper expects, so no resampling is needed.
    static let sampleRate = 16_000

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "LiveSubtitles.AudioCapture")
    private var peak: Float = 0
    private var lastLevelReport = Date.distantPast

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw AudioCaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Self.sampleRate
        config.channelCount = 1
        // Video is mandatory for an SCStream; keep it as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // Registered only so ScreenCaptureKit doesn't log dropped-frame errors; frames are ignored.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        let samples = Self.samples(of: sampleBuffer)
        guard !samples.isEmpty else { return }
        onAudio?(samples)

        peak = max(peak, samples.reduce(0) { max($0, abs($1)) })
        let now = Date()
        if now.timeIntervalSince(lastLevelReport) >= 0.5 {
            onLevel?(peak)
            peak = 0
            lastLevelReport = now
        }
    }

    /// ScreenCaptureKit delivers 32-bit float PCM, one plane per channel; the first plane is all we need.
    private static func samples(of sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let block = sampleBuffer.dataBuffer else { return [] }
        let count = min(sampleBuffer.numSamples, CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        let status = samples.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? samples : []
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop?(error)
    }
}
