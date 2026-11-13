import Foundation
import Speech
import SwiftUI
import Translation

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // MARK: Settings

    @Published var sourceLocaleID: String { didSet { save(sourceLocaleID, "sourceLocale") } }
    @Published var targetLanguageID: String { didSet { save(targetLanguageID, "targetLanguage") } }
    @Published var fontSize: Double { didSet { save(fontSize, "fontSize") } }
    @Published var showOriginal: Bool { didSet { save(showOriginal, "showOriginal") } }

    // MARK: State

    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var status = "대기 중"
    @Published private(set) var originalText = ""
    @Published private(set) var translatedText = ""

    let sourceOptions: [LanguageOption]
    let targetOptions: [LanguageOption]

    private let capture = AudioCapture()
    private var transcriber: SpeechTranscriber?
    private var requests: AsyncStream<String>.Continuation?
    private var clearTask: Task<Void, Never>?

    private static let targetLanguageIDs = [
        "ko", "en", "ja", "zh-Hans", "zh-Hant", "es", "fr", "de", "it", "pt", "ru",
        "ar", "hi", "id", "th", "vi", "tr", "pl", "nl", "uk",
    ]
    /// How long a subtitle stays on screen after the audio goes quiet.
    private static let subtitleLifetime: Duration = .seconds(6)

    private init() {
        let defaults = UserDefaults.standard
        let display = Locale.current
        sourceOptions = SFSpeechRecognizer.supportedLocales()
            .map { LanguageOption(id: $0.identifier, name: display.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
            .sorted { $0.name < $1.name }
        targetOptions = Self.targetLanguageIDs
            .map { LanguageOption(id: $0, name: display.localizedString(forIdentifier: $0) ?? $0) }

        let savedSource = defaults.string(forKey: "sourceLocale") ?? "en-US"
        sourceLocaleID = sourceOptions.contains { $0.id == savedSource } ? savedSource : (sourceOptions.first?.id ?? "en-US")
        targetLanguageID = defaults.string(forKey: "targetLanguage") ?? "ko"
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 32
        showOriginal = defaults.bool(forKey: "showOriginal")
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    // MARK: Languages

    /// The spoken language, in the form the Translation framework expects.
    private var sourceLanguage: Locale.Language {
        let language = Locale(identifier: sourceLocaleID).language
        guard let code = language.languageCode else { return language }
        if code == .chinese {
            let traditional = ["TW", "HK", "MO"].contains(language.region?.identifier ?? "")
            return Locale.Language(languageCode: code, script: traditional ? .hanTraditional : .hanSimplified)
        }
        return Locale.Language(languageCode: code)
    }

    private var targetLanguage: Locale.Language {
        Locale.Language(identifier: targetLanguageID)
    }

    private var needsTranslation: Bool {
        let source = sourceLanguage, target = targetLanguage
        return source.languageCode != target.languageCode || source.script != target.script
    }

    /// Nil when the spoken and subtitle languages are the same (plain captions, no translation).
    var translationConfiguration: TranslationSession.Configuration? {
        needsTranslation ? .init(source: sourceLanguage, target: targetLanguage) : nil
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

        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else {
            status = "음성 인식 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 음성 인식에서 허용해 주세요."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: sourceLocaleID)), recognizer.isAvailable else {
            status = "선택한 언어의 음성 인식을 지금 사용할 수 없습니다."
            return
        }
        if needsTranslation {
            let availability = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
            if availability == .unsupported {
                status = "이 언어 조합은 번역이 지원되지 않습니다."
                return
            }
        }

        let transcriber = SpeechTranscriber(recognizer: recognizer)
        transcriber.onPartial = { [weak self] text in
            MainActor.assumeIsolated { self?.received(text) }
        }
        transcriber.onFinal = { [weak self] text in
            MainActor.assumeIsolated { self?.received(text) }
        }
        capture.onAudio = { [transcriber] buffer in transcriber.append(buffer) }
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
        status = recognizer.supportsOnDeviceRecognition ? "듣는 중 (온디바이스 인식)" : "듣는 중 (서버 인식)"
    }

    private func stop() async {
        isRunning = false
        transcriber?.stop()
        transcriber = nil
        await capture.stop()
        clearTask?.cancel()
        originalText = ""
        translatedText = ""
        status = "대기 중"
    }

    // MARK: Subtitles

    private func received(_ text: String) {
        guard isRunning else { return }
        originalText = text
        if needsTranslation {
            // Only the newest pending text is kept, so translation never falls behind the audio.
            requests?.yield(text)
        } else {
            translatedText = text
        }
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

    /// Runs for as long as the translation session provided by SwiftUI is valid.
    func runTranslation(with session: TranslationSession) async {
        // Offers to download the language pair if it isn't installed yet.
        try? await session.prepareTranslation()

        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        requests = continuation
        for await text in stream {
            do {
                let response = try await session.translate(text)
                guard isRunning else { continue }
                translatedText = response.targetText
                scheduleClear()
            } catch {
                if Task.isCancelled { break }
                status = "번역 오류: \(error.localizedDescription)"
            }
        }
    }
}
