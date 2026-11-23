import Foundation

/// Something the Mac can be told to do.
enum Command: Equatable {
    case setVolume(Int)  // percent
    case changeVolume(Int)  // percent points, signed
    case setMuted(Bool)
    case setBrightness(Int)  // percent
    case changeBrightness(Int)  // percent points, signed
    case setDarkMode(Bool)
    case sleep
    case sleepDisplay
    case lockScreen
    case playPause
    case nextTrack
    case previousTrack
    case seek(forward: Bool)
    case screenshot
    /// The spoken request, compacted; the app to open is looked up among the installed ones.
    case openApp(String)
    case quitApp(String)
}

/// Turns recognized speech into commands by keyword, in Korean and English.
///
/// Everything works on "compact" text (lowercased, with spaces and punctuation removed) because a
/// recognizer spaces Korean unpredictably: "볼륨 올려 줘" and "볼륨올려줘" must mean the same thing.
enum CommandParser {
    static let step = 10

    static func compact(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// What follows the wake word, compacted. Nil if the wake word wasn't said; empty if nothing follows it.
    static func textAfterWakeWord(in text: String, wakeWords: [String]) -> String? {
        let text = compact(text)
        let matches = wakeWords.map(compact).filter { !$0.isEmpty }.compactMap { text.range(of: $0) }
        // The earliest match; of several starting there ("헤이 맥", "헤이 맥북"), the longest.
        let first = matches.min {
            $0.lowerBound != $1.lowerBound ? $0.lowerBound < $1.lowerBound : $0.upperBound > $1.upperBound
        }
        guard let first else { return nil }
        return String(text[first.upperBound...])
    }

    static func parse(_ text: String) -> Command? {
        let text = compact(text)
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }

        let raises = has("올려", "올리", "높여", "높이", "키워", "크게", "밝게", "up", "louder", "brighter", "increase", "raise")
        let lowers = has(
            "내려", "내리", "낮춰", "낮추", "줄여", "줄이", "작게", "어둡게", "down", "quieter", "dimmer", "darker",
            "decrease", "lower")
        let turnsOff = has("꺼", "끄", "해제", "off")

        if has("음소거해제", "소리켜", "unmute") { return .setMuted(false) }
        if has("음소거", "뮤트", "mute") { return .setMuted(!turnsOff) }

        if has("밝기", "brightness") || (has("화면", "screen") && has("밝게", "어둡게", "brighter", "dimmer", "darker")) {
            let level = absoluteLevel(in: text)
            // "밝기 20 올려" is a relative change; "밝기 20으로" is an absolute one.
            if raises { return .changeBrightness(level ?? step) }
            if lowers { return .changeBrightness(-(level ?? step)) }
            return level.map(Command.setBrightness)
        }
        if has("볼륨", "음량", "소리", "volume", "sound") {
            let level = absoluteLevel(in: text)
            if raises { return .changeVolume(level ?? step) }
            if lowers { return .changeVolume(-(level ?? step)) }
            if let level { return .setVolume(level) }
            return turnsOff ? .setMuted(true) : nil
        }

        if has("다크모드", "darkmode") { return .setDarkMode(!turnsOff) }
        if has("라이트모드", "lightmode") { return .setDarkMode(turnsOff) }

        // Not a bare "lock": that would also catch "open Clock".
        if has("잠금", "잠가", "lockscreen", "lockthe", "lockmy") || text == "lock" { return .lockScreen }
        let display = has("화면", "디스플레이", "모니터", "display", "screen", "monitor")
        if has("잠자기", "슬립", "절전", "잠들", "재워", "sleep") { return display ? .sleepDisplay : .sleep }
        if display, turnsOff { return .sleepDisplay }

        if has("스크린샷", "캡처", "캡쳐", "screenshot", "capture") { return .screenshot }

        if has("앞으로", "빨리감", "forward") { return .seek(forward: true) }
        if has("뒤로", "되감", "rewind", "backward") { return .seek(forward: false) }
        if has("다음", "넘겨", "스킵", "next", "skip") { return .nextTrack }
        if has("이전", "previous") { return .previousTrack }
        if has("일시정지", "정지", "멈춰", "멈춤", "pause", "stop", "재생", "플레이", "틀어", "play", "resume") {
            return .playPause
        }

        if has("열어", "실행", "켜", "open", "launch") { return .openApp(text) }
        if has("닫아", "종료", "꺼", "quit", "close") { return .quitApp(text) }
        return nil
    }

    /// An absolute level in percent: a number, or a word such as "최대" or "half".
    private static func absoluteLevel(in text: String) -> Int? {
        if let digits = text.range(of: "[0-9]+", options: .regularExpression), let number = Int(text[digits]) {
            return min(number, 100)
        }
        if ["최대", "끝까지", "max", "full"].contains(where: text.contains) { return 100 }
        if ["절반", "반으로", "half"].contains(where: text.contains) { return 50 }
        if ["최소", "minimum"].contains(where: text.contains) { return 0 }
        return nil
    }
}
