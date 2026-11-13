import Foundation
import SwiftUI
import Translation
import WhisperKit

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let automatic = "auto"

    // MARK: Settings

    /// Whisper language code of the audio, or `automatic` to detect it utterance by utterance.
    @Published var audioLanguageID: String { didSet { save(audioLanguageID, "audioLanguage") } }
    @Published var targetLanguageID: String { didSet { save(targetLanguageID, "targetLanguage") } }
    @Published var fontSize: Double { didSet { save(fontSize, "fontSize") } }
    @Published var showOriginal: Bool { didSet { save(showOriginal, "showOriginal") } }

    // MARK: State

    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var status = "대기 중"
    @Published private(set) var originalText = ""
    @Published private(set) var translatedText = ""
    /// The latest recognized speech, shown in the settings window so a silent overlay can be diagnosed.
    @Published private(set) var heardText = ""
    /// Loudest captured sample over the last half second; nil until audio buffers start arriving.
    @Published private(set) var audioLevel: Float?
    @Published private(set) var recognitionError = ""
    /// Spoken languages (Whisper codes) that need a translation session; the settings window keeps one open for each.
    @Published private(set) var translationSources: [String] = []

    let audioOptions: [LanguageOption]
    let targetOptions: [LanguageOption]

    private let capture = AudioCapture()
    private var whisper: WhisperKit?
    private var transcriber: WhisperTranscriber?
    private var clearTask: Task<Void, Never>?

    /// Open translation sessions by spoken language. The id tells a restarted session's stream from the one it replaced.
    private var streams: [String: (id: Int, continuation: AsyncStream<String>.Continuation)] = [:]
    private var nextStreamID = 0
    /// Speech waiting for its language's translation session to come up.
    private var backlog: [String: [String]] = [:]
    private var checking: Set<String> = []
    private var untranslatable: Set<String> = []

    private static let audioLanguageIDs = [
        "en", "ko", "ja", "zh", "es", "fr", "de", "it", "pt", "ru",
        "ar", "hi", "id", "th", "vi", "tr", "pl", "nl", "uk",
    ]
    private static let targetLanguageIDs = [
        "ko", "en", "ja", "zh-Hans", "zh-Hant", "es", "fr", "de", "it", "pt", "ru",
        "ar", "hi", "id", "th", "vi", "tr", "pl", "nl", "uk",
    ]
    /// How long a subtitle stays on screen after the audio goes quiet.
    private static let subtitleLifetime: Duration = .seconds(6)
    private static let maxBacklog = 3

    private init() {
        let defaults = UserDefaults.standard
        let display = Locale.current
        func option(_ id: String) -> LanguageOption {
            LanguageOption(id: id, name: display.localizedString(forIdentifier: id) ?? id)
        }
        audioOptions = [LanguageOption(id: Self.automatic, name: "자동 감지")] + Self.audioLanguageIDs.map(option)
        targetOptions = Self.targetLanguageIDs.map(option)

        let savedAudio = defaults.string(forKey: "audioLanguage") ?? Self.automatic
        audioLanguageID = audioOptions.contains { $0.id == savedAudio } ? savedAudio : Self.automatic
        targetLanguageID = defaults.string(forKey: "targetLanguage") ?? "ko"
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 32
        showOriginal = defaults.bool(forKey: "showOriginal")
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    // MARK: Languages

    private var targetLanguage: Locale.Language {
        Locale.Language(identifier: targetLanguageID)
    }

    /// A Whisper language code in the form the Translation framework expects.
    private func language(for source: String) -> Locale.Language {
        Locale.Language(identifier: source == "zh" ? "zh-Hans" : source)
    }

    private func isTargetLanguage(_ source: String) -> Bool {
        language(for: source).languageCode == targetLanguage.languageCode
    }

    /// Nil when that language is already the subtitle language (plain captions, no translation).
    func translationConfiguration(from source: String) -> TranslationSession.Configuration? {
        isTargetLanguage(source) ? nil : .init(source: language(for: source), target: targetLanguage)
    }

    // MARK: Start / stop

    func toggle() {
        if isRunning {
            Task { await stop() }
        } else if !isStarting {
            Task { await start() }
        }
    }

    private func start() async {
        isStarting = true
        defer { isStarting = false }

        let whisper: WhisperKit
        do {
            whisper = try await loadWhisper()
        } catch {
            status = "음성 인식 모델을 준비하지 못했습니다. 인터넷 연결을 확인하고 다시 시도해 주세요. (\(error.localizedDescription))"
            return
        }

        let transcriber = WhisperTranscriber(
            whisper: whisper, language: audioLanguageID == Self.automatic ? nil : audioLanguageID)
        transcriber.onUtterance = { [weak self] utterance in
            MainActor.assumeIsolated { self?.received(utterance) }
        }
        transcriber.onError = { [weak self] message in
            MainActor.assumeIsolated { self?.recognitionError = message }
        }
        capture.onAudio = { [transcriber] samples in transcriber.append(samples) }
        capture.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.audioLevel = level
            }
        }
        capture.onStop = { [weak self] error in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                await self.stop()
                self.status = "오디오 캡처가 중단되었습니다: \(error.localizedDescription)"
            }
        }

        do {
            try await capture.start()
        } catch {
            status = "시스템 오디오를 캡처할 수 없습니다. 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음에서 허용한 뒤 앱을 다시 실행해 주세요. (\(error.localizedDescription))"
            return
        }
        transcriber.start()
        self.transcriber = transcriber
        isRunning = true
        status = "듣는 중"
    }

    /// Downloads the Whisper model on first use (several hundred MB) and loads it; later calls reuse it.
    private func loadWhisper() async throws -> WhisperKit {
        if let whisper { return whisper }

        let model = WhisperKit.recommendedModels().default
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveSubtitles", isDirectory: true)
        let folderKey = "whisperModelFolder.\(model)"

        var folder = UserDefaults.standard.string(forKey: folderKey)
        if folder.map(FileManager.default.fileExists(atPath:)) != true {
            status = "음성 인식 모델 다운로드 중…"
            let url = try await WhisperKit.download(variant: model, downloadBase: base) { progress in
                let percent = Int(progress.fractionCompleted * 100)
                Task { @MainActor [weak self] in self?.status = "음성 인식 모델 다운로드 중… \(percent)%" }
            }
            folder = url.path
            UserDefaults.standard.set(url.path, forKey: folderKey)
        }

        status = "음성 인식 모델 불러오는 중… (처음에는 몇 분 걸릴 수 있습니다)"
        do {
            let whisper = try await WhisperKit(WhisperKitConfig(
                model: model, downloadBase: base, modelFolder: folder, verbose: false, prewarm: false, load: true,
                download: false))
            self.whisper = whisper
            return whisper
        } catch {
            // Possibly an incomplete download; fetch it again next time.
            UserDefaults.standard.removeObject(forKey: folderKey)
            throw error
        }
    }

    private func stop() async {
        isRunning = false
        transcriber?.stop()
        transcriber = nil
        await capture.stop()
        clearTask?.cancel()
        backlog = [:]
        heardText = ""
        audioLevel = nil
        recognitionError = ""
        originalText = ""
        translatedText = ""
        status = "대기 중"
    }

    // MARK: Subtitles

    private func received(_ utterance: WhisperTranscriber.Utterance) {
        guard isRunning else { return }
        let text = utterance.text, source = utterance.language
        heardText = text
        recognitionError = ""

        if isTargetLanguage(source) || untranslatable.contains(source) {
            show(original: text, translated: text)
            return
        }
        if let stream = streams[source] {
            stream.continuation.yield(text)
            return
        }

        backlog[source] = Array(((backlog[source] ?? []) + [text]).suffix(Self.maxBacklog))
        guard !translationSources.contains(source), !checking.contains(source) else { return }
        // A language heard once in the middle of another is usually a misdetection; wait for a second utterance.
        if !translationSources.isEmpty, backlog[source]?.count == 1 { return }

        checking.insert(source)
        Task {
            let availability = await LanguageAvailability().status(from: language(for: source), to: targetLanguage)
            checking.remove(source)
            if availability == .unsupported {
                // Better the original words than nothing.
                untranslatable.insert(source)
                for text in backlog.removeValue(forKey: source) ?? [] { show(original: text, translated: text) }
            } else {
                translationSources.append(source)
            }
        }
    }

    private func show(original: String, translated: String) {
        originalText = original
        translatedText = translated
        scheduleClear()
    }

    private func scheduleClear() {
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: Self.subtitleLifetime)
            guard !Task.isCancelled else { return }
            self?.originalText = ""
            self?.translatedText = ""
        }
    }

    /// Translates everything spoken in one language, for as long as the session SwiftUI provided is valid.
    func runTranslation(with session: TranslationSession, from source: String) async {
        // Offers to download the language pair if it isn't installed yet.
        try? await session.prepareTranslation()

        let (stream, continuation) = AsyncStream<String>.makeStream()
        nextStreamID += 1
        let id = nextStreamID
        streams[source] = (id, continuation)
        defer { if streams[source]?.id == id { streams[source] = nil } }
        for text in backlog.removeValue(forKey: source) ?? [] { continuation.yield(text) }

        for await text in stream {
            do {
                let response = try await session.translate(text)
                guard isRunning else { continue }
                show(original: text, translated: response.targetText)
            } catch {
                if Task.isCancelled { break }
                recognitionError = "번역 오류: \(error.localizedDescription)"
            }
        }
    }
}
