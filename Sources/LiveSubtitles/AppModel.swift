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
    /// What the recognizer currently hears, shown in the settings window so a silent overlay can be diagnosed.
    @Published private(set) var heardText = ""
    /// Loudest captured sample over the last half second; nil until audio buffers start arriving.
    @Published private(set) var audioLevel: Float?
    @Published private(set) var recognitionError = ""

    let sourceOptions: [LanguageOption]
    let targetOptions: [LanguageOption]

    private let capture = AudioCapture()
    private var transcriber: SpeechTranscriber?
    private var requests: AsyncStream<String>.Continuation?
    private var clearTask: Task<Void, Never>?
    /// Number of characters of the segment in progress that were already shown as sentences.
    private var committed = 0
    /// Words of an unfinished sentence left over when a segment ended, waiting to be joined with what comes next.
    private var pending = ""
    private var flushTask: Task<Void, Never>?

    private static let targetLanguageIDs = [
        "ko", "en", "ja", "zh-Hans", "zh-Hant", "es", "fr", "de", "it", "pt", "ru",
        "ar", "hi", "id", "th", "vi", "tr", "pl", "nl", "uk",
    ]
    /// How long a subtitle stays on screen after the audio goes quiet.
    private static let subtitleLifetime: Duration = .seconds(6)
    /// How long an unfinished sentence waits for the speaker to continue before it is shown as is.
    private static let pendingLifetime: Duration = .seconds(2)
    private static let maxPendingLength = 150

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
            MainActor.assumeIsolated { self?.received(text, isFinal: false) }
        }
        transcriber.onFinal = { [weak self] text in
            MainActor.assumeIsolated { self?.received(text, isFinal: true) }
        }
        transcriber.onError = { [weak self] message in
            MainActor.assumeIsolated { self?.recognitionError = message }
        }
        capture.onAudio = { [transcriber] buffer in transcriber.append(buffer) }
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
        status = recognizer.supportsOnDeviceRecognition ? "듣는 중 (온디바이스 인식)" : "듣는 중 (서버 인식)"
    }

    private func stop() async {
        isRunning = false
        transcriber?.stop()
        transcriber = nil
        await capture.stop()
        clearTask?.cancel()
        flushTask?.cancel()
        committed = 0
        pending = ""
        heardText = ""
        audioLevel = nil
        recognitionError = ""
        originalText = ""
        translatedText = ""
        status = "대기 중"
    }

    // MARK: Subtitles

    /// Subtitles advance one finished sentence at a time, so the text on screen never rewrites itself
    /// while the recognizer is still revising its guess.
    private func received(_ text: String, isFinal: Bool) {
        guard isRunning else { return }
        heardText = text
        recognitionError = ""
        flushTask?.cancel()

        let characters = Array(text)
        // The recognizer sometimes starts its transcript over mid-segment.
        if characters.count < committed { committed = 0 }
        let end = Self.lastSentenceEnd(in: characters, requiringTextAfter: !isFinal)
        if end > committed {
            emit(joined(pending, String(characters[committed..<end])))
            pending = ""
            committed = end
        }
        guard isFinal else { return }

        // The segment ended mid-sentence (a breath, or the length limit). Hold the words back and
        // translate them together with whatever comes next, instead of as a fragment on their own.
        let carriedOver = !pending.isEmpty
        pending = joined(pending, String(characters[committed...]))
        committed = 0
        guard !pending.isEmpty else { return }
        if carriedOver || pending.count > Self.maxPendingLength {
            flushPending()
        } else {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: Self.pendingLifetime)
                guard !Task.isCancelled else { return }
                self?.flushPending()
            }
        }
    }

    private func flushPending() {
        flushTask?.cancel()
        let sentence = pending
        pending = ""
        emit(sentence)
    }

    private func joined(_ first: String, _ second: String) -> String {
        let first = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if first.isEmpty || second.isEmpty { return first + second }
        let unspaced: [Locale.LanguageCode] = [.japanese, .chinese, .thai]
        let separator = sourceLanguage.languageCode.map(unspaced.contains) == true ? "" : " "
        return first + separator + second
    }

    /// Index just past the last sentence terminator. While the segment is still in progress the terminator
    /// must already have more speech after it, so a sentence isn't cut at punctuation the recognizer later revises.
    private static func lastSentenceEnd(in characters: [Character], requiringTextAfter: Bool) -> Int {
        var canEnd = !requiringTextAfter
        for index in characters.indices.reversed() {
            let character = characters[index]
            if canEnd {
                if "。？！?!".contains(character) { return index + 1 }
                // A period only ends a sentence at the end or before a space ("3.5" and "U.S.A" don't).
                if character == ".", index + 1 == characters.count || characters[index + 1].isWhitespace {
                    return index + 1
                }
            }
            if !character.isWhitespace { canEnd = true }
        }
        return 0
    }

    private func emit(_ sentence: String) {
        guard !sentence.isEmpty else { return }
        if needsTranslation {
            requests?.yield(sentence)
        } else {
            show(original: sentence, translated: sentence)
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

    /// Runs for as long as the translation session provided by SwiftUI is valid.
    func runTranslation(with session: TranslationSession) async {
        // Offers to download the language pair if it isn't installed yet.
        try? await session.prepareTranslation()

        let (stream, continuation) = AsyncStream<String>.makeStream()
        requests = continuation
        for await text in stream {
            do {
                let response = try await session.translate(text)
                guard isRunning else { continue }
                show(original: text, translated: response.targetText)
            } catch {
                if Task.isCancelled { break }
                status = "번역 오류: \(error.localizedDescription)"
            }
        }
    }
}
