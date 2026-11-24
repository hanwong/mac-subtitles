import AppKit
import AVFoundation
import Foundation
import WhisperKit

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum State: Equatable {
        case loading(String)
        /// Waiting for the wake word.
        case listening
        /// The wake word was heard; the next thing said is the command.
        case armed
        case failed(String)
    }

    /// The banner shown at the top of the screen.
    struct Banner: Equatable {
        enum Kind { case listening, done, failed }
        let kind: Kind
        let text: String
    }

    // MARK: Settings

    /// Comma-separated spellings of the wake word; the recognizer doesn't always write it the same way.
    @Published var wakeWords: String {
        didSet {
            UserDefaults.standard.set(wakeWords, forKey: "wakeWords")
            scheduleListenerRestart()
        }
    }
    @Published var languageID: String {
        didSet {
            UserDefaults.standard.set(languageID, forKey: "language")
            if oldValue != languageID { restartListener() }
        }
    }
    @Published var playsSounds: Bool { didSet { UserDefaults.standard.set(playsSounds, forKey: "playsSounds") } }

    // MARK: State

    @Published private(set) var state = State.loading("준비 중…")
    @Published private(set) var heardText = ""
    @Published private(set) var banner: Banner?

    let languages = ["ko", "en", "ja"].map { (id: $0, name: Locale.current.localizedString(forIdentifier: $0) ?? $0) }

    private var whisper: WhisperKit?
    private var listener: SpeechListener?
    private var armedUntil: Date?
    private var bannerTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?

    static let defaultWakeWords = "헤이 맥, 해이 맥, 하이 맥, 헤이 맥북, hey mac"
    /// How long after the wake word a command is still accepted.
    private static let armedDuration: TimeInterval = 8
    private static let bannerDuration: Duration = .seconds(3)

    private init() {
        let defaults = UserDefaults.standard
        wakeWords = defaults.string(forKey: "wakeWords") ?? Self.defaultWakeWords
        languageID = defaults.string(forKey: "language") ?? "ko"
        playsSounds = defaults.object(forKey: "playsSounds") as? Bool ?? true
    }

    private var wakeWordList: [String] {
        wakeWords.split(separator: ",").map(String.init)
    }

    /// Example requests in the command language, starting with the wake word as the user spells it.
    private var recognitionHint: String {
        let wakeWord = wakeWordList.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let examples: [String]
        switch languageID {
        case "ko": examples = ["볼륨 올려줘", "화면 밝기 낮춰줘", "일시정지", "다음 곡", "잠자기", "사파리 열어줘"]
        case "en": examples = ["volume up", "brightness down", "pause", "next track", "go to sleep", "open Safari"]
        default: examples = []
        }
        return ([wakeWord] + examples.map { "\(wakeWord), \($0)" }).joined(separator: ". ")
    }

    // MARK: Start

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            state = .failed("마이크 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 Hey Mac을 허용한 뒤 다시 실행해 주세요.")
            return
        }
        do {
            whisper = try await loadWhisper()
        } catch {
            state = .failed("음성 인식 모델을 준비하지 못했습니다. 인터넷 연결을 확인하고 다시 실행해 주세요. (\(error.localizedDescription))")
            return
        }
        restartListener()
    }

    /// Downloads the Whisper model on first use (several hundred MB) and loads it.
    private func loadWhisper() async throws -> WhisperKit {
        let model = WhisperKit.recommendedModels().default
        // The same folder Live Subtitles uses, so the model is downloaded once for both apps.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveSubtitles", isDirectory: true)
        let folderKey = "whisperModelFolder.\(model)"

        var folder = UserDefaults.standard.string(forKey: folderKey)
        if folder.map(FileManager.default.fileExists(atPath:)) != true {
            state = .loading("음성 인식 모델 다운로드 중…")
            let url = try await WhisperKit.download(variant: model, downloadBase: base) { progress in
                let percent = Int(progress.fractionCompleted * 100)
                Task { @MainActor [weak self] in self?.state = .loading("음성 인식 모델 다운로드 중… \(percent)%") }
            }
            folder = url.path
            UserDefaults.standard.set(url.path, forKey: folderKey)
        }

        state = .loading("음성 인식 모델 불러오는 중… (처음에는 몇 분 걸릴 수 있습니다)")
        do {
            return try await WhisperKit(WhisperKitConfig(
                model: model, downloadBase: base, modelFolder: folder, verbose: false, prewarm: false, load: true,
                download: false))
        } catch {
            // Possibly an incomplete download; fetch it again next time.
            UserDefaults.standard.removeObject(forKey: folderKey)
            throw error
        }
    }

    /// The wake word is part of the recognizer's hint, so editing it needs a restart; wait until typing stops.
    private func scheduleListenerRestart() {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.restartListener()
        }
    }

    private func restartListener() {
        guard let whisper else { return }
        listener?.stop()
        let listener = SpeechListener(whisper: whisper, language: languageID, hint: recognitionHint)
        listener.onUtterance = { [weak self] text in
            MainActor.assumeIsolated { self?.heard(text) }
        }
        listener.onError = { [weak self] message in
            MainActor.assumeIsolated { self?.state = .failed(message) }
        }
        do {
            try listener.start()
            self.listener = listener
            state = .listening
        } catch {
            state = .failed("마이크를 시작하지 못했습니다. (\(error.localizedDescription))")
        }
    }

    // MARK: Commands

    /// Accepts the next thing said as a command, as if the wake word had just been spoken.
    func arm() {
        guard state == .listening || state == .armed else { return }
        armedUntil = Date().addingTimeInterval(Self.armedDuration)
        state = .armed
        play("Tink")
        show(Banner(kind: .listening, text: "네, 말씀하세요"), for: .seconds(Self.armedDuration)) { [weak self] in
            guard let self, self.state == .armed else { return }
            self.armedUntil = nil
            self.state = .listening
        }
    }

    private func heard(_ text: String) {
        heardText = text
        let afterWakeWord = CommandParser.textAfterWakeWord(in: text, wakeWords: wakeWordList)

        if let armedUntil, Date() < armedUntil {
            // Saying the wake word again is harmless; whatever comes with it is the command.
            let request = afterWakeWord ?? CommandParser.compact(text)
            if request.isEmpty { return }
            self.armedUntil = nil
            state = .listening
            execute(request, spoken: text)
        } else if let afterWakeWord {
            // The wake word alone, give or take a stray syllable: wait for the command.
            if afterWakeWord.count < 2 { arm() } else { execute(afterWakeWord, spoken: text) }
        }
    }

    private func execute(_ request: String, spoken: String) {
        guard let command = CommandParser.parse(request) else {
            play("Basso")
            show(Banner(kind: .failed, text: "이해하지 못했어요: \(spoken)"))
            return
        }
        let outcome = SystemController.perform(command)
        play(outcome.succeeded ? "Pop" : "Basso")
        show(Banner(kind: outcome.succeeded ? .done : .failed, text: outcome.message))
    }

    // MARK: Feedback

    private func show(_ banner: Banner, for duration: Duration = AppModel.bannerDuration, then: (() -> Void)? = nil) {
        bannerTask?.cancel()
        self.banner = banner
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.banner = nil
            then?()
        }
    }

    private func play(_ sound: String) {
        if playsSounds { NSSound(named: sound)?.play() }
    }
}
