import AppKit
import ApplicationServices
import Foundation

/// Carries out commands on this Mac. Every call returns a short sentence describing what happened.
@MainActor
enum SystemController {
    struct Outcome {
        let message: String
        let succeeded: Bool

        static func done(_ message: String) -> Outcome { Outcome(message: message, succeeded: true) }
        static func failed(_ message: String) -> Outcome { Outcome(message: message, succeeded: false) }
    }

    static func perform(_ command: Command) -> Outcome {
        switch command {
        case .setVolume(let percent): return setVolume(percent)
        case .changeVolume(let delta): return setVolume((volume() ?? 50) + delta)
        case .setMuted(let muted):
            guard runAppleScript("set volume \(muted ? "with" : "without") output muted") != nil else {
                return .failed("음량을 바꾸지 못했어요")
            }
            return .done(muted ? "음소거" : "음소거 해제")
        case .setBrightness(let percent): return setBrightness(percent)
        case .changeBrightness(let delta): return changeBrightness(delta)
        case .setDarkMode(let dark):
            let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)"
            guard runAppleScript(script) != nil else {
                return .failed("다크 모드를 바꾸지 못했어요. 시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 허용해 주세요")
            }
            return .done(dark ? "다크 모드" : "라이트 모드")
        case .sleep:
            // Give the confirmation a moment on screen before everything goes dark.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { run("/usr/bin/pmset", "sleepnow") }
            return .done("잠자기")
        case .sleepDisplay:
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { run("/usr/bin/pmset", "displaysleepnow") }
            return .done("화면 끄기")
        case .lockScreen:
            return pressKey(12, flags: [.maskCommand, .maskControl], then: "화면 잠금")  // ⌃⌘Q
        case .playPause: return pressMediaKey(16, then: "재생/일시정지")
        case .nextTrack: return pressMediaKey(17, then: "다음")
        case .previousTrack: return pressMediaKey(18, then: "이전")
        case .seek(let forward):
            return pressKey(forward ? 124 : 123, flags: [], then: forward ? "앞으로" : "뒤로")  // → / ←
        case .screenshot:
            return pressKey(20, flags: [.maskCommand, .maskShift], then: "스크린샷")  // ⇧⌘3
        case .openApp(let request):
            guard let app = Applications.find(in: request) else { return .failed("어떤 앱인지 찾지 못했어요") }
            NSWorkspace.shared.openApplication(at: app.url, configuration: .init())
            return .done("\(app.name) 열기")
        case .quitApp(let request):
            guard let app = Applications.find(in: request) else { return .failed("어떤 앱인지 찾지 못했어요") }
            let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL == app.url }
            guard !running.isEmpty else { return .failed("\(app.name)은(는) 실행 중이 아니에요") }
            running.forEach { $0.terminate() }
            return .done("\(app.name) 종료")
        }
    }

    // MARK: Volume

    private static func volume() -> Int? {
        runAppleScript("output volume of (get volume settings)").map { Int($0.int32Value) }
    }

    private static func setVolume(_ percent: Int) -> Outcome {
        let percent = min(max(percent, 0), 100)
        guard runAppleScript("set volume output volume \(percent)") != nil else { return .failed("음량을 바꾸지 못했어요") }
        return .done("음량 \(percent)%")
    }

    // MARK: Brightness

    /// Brightness of the built-in display goes through DisplayServices, a private framework: there is no public API.
    private enum DisplayServices {
        typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32

        private static let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        static let get = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Getter.self) }
        static let set = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Setter.self) }
    }

    private static func brightness() -> Float? {
        var value: Float = 0
        guard let get = DisplayServices.get, get(CGMainDisplayID(), &value) == 0 else { return nil }
        return value
    }

    private static func setBrightness(_ percent: Int) -> Outcome {
        let percent = min(max(percent, 0), 100)
        guard let set = DisplayServices.set, set(CGMainDisplayID(), Float(percent) / 100) == 0 else {
            return .failed("이 디스플레이는 밝기를 숫자로 지정할 수 없어요")
        }
        return .done("밝기 \(percent)%")
    }

    private static func changeBrightness(_ delta: Int) -> Outcome {
        if let current = brightness() {
            return setBrightness(Int((current * 100).rounded()) + delta)
        }
        // External displays and the like: fall back to the keyboard's brightness keys, one press per 6%.
        let presses = max(1, abs(delta) / 6)
        var outcome = Outcome.done("")
        for _ in 0..<presses { outcome = pressMediaKey(delta > 0 ? 2 : 3, then: delta > 0 ? "밝게" : "어둡게") }
        return outcome
    }

    // MARK: Keys

    private static let accessibilityHint = "키 입력을 보내려면 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 Hey Mac을 허용해 주세요"

    /// Whether the app may post key events. Asks the user (once per launch, by macOS) when it may not.
    @discardableResult
    static func ensureAccessibility(prompt: Bool = true) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags, then message: String) -> Outcome {
        guard ensureAccessibility() else { return .failed(accessibilityHint) }
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        return .done(message)
    }

    /// Presses one of the keyboard's special keys (NX_KEYTYPE_*): brightness 2/3, play 16, next 17, previous 18.
    private static func pressMediaKey(_ key: Int, then message: String) -> Outcome {
        guard ensureAccessibility() else { return .failed(accessibilityHint) }
        for keyDown in [true, false] {
            let state = keyDown ? 0xa : 0xb
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (key << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        return .done(message)
    }

    // MARK: Helpers

    private static func runAppleScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    nonisolated private static func run(_ path: String, _ arguments: String...) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
    }
}

/// Finds installed applications by the names people say out loud.
@MainActor
enum Applications {
    struct App {
        let name: String
        let url: URL
    }

    /// Korean pronunciations of apps whose names are written in English.
    private static let spokenNames: [String: String] = [
        "크롬": "chrome", "사파리": "safari", "파인더": "finder", "터미널": "terminal", "슬랙": "slack",
        "카카오톡": "kakaotalk", "카톡": "kakaotalk", "노션": "notion", "스포티파이": "spotify", "디스코드": "discord",
        "줌": "zoom", "엑스코드": "xcode", "피그마": "figma", "파이어폭스": "firefox", "유튜브뮤직": "youtubemusic",
        "브이에스코드": "visualstudiocode", "비주얼스튜디오코드": "visualstudiocode", "텔레그램": "telegram",
        "뮤직": "music", "설정": "systemsettings", "시스템설정": "systemsettings",
    ]

    private struct Entry {
        let compactName: String
        let app: App
    }

    private static let installed: [Entry] = {
        let manager = FileManager.default
        let folders = [
            "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        var apps: [Entry] = []
        for folder in folders {
            for item in (try? manager.contentsOfDirectory(atPath: folder)) ?? [] where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(item)
                // The localized name ("사파리") and the file name ("Safari") can both be what the user says.
                let displayName = manager.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                let fileName = String(item.dropLast(4))
                for name in Set([displayName, fileName]) {
                    apps.append(Entry(compactName: CommandParser.compact(name), app: App(name: displayName, url: url)))
                }
            }
        }
        return apps
    }()

    /// The app named in a compacted request such as "사파리열어줘" or "openchrome". The longest name wins.
    static func find(in request: String) -> App? {
        var candidates = installed.filter { $0.compactName.count >= 2 && request.contains($0.compactName) }
        for (spoken, written) in spokenNames where request.contains(spoken) {
            candidates += installed.filter { $0.compactName.contains(written) }
                // "chrome" should find "Google Chrome", not "Chrome Remote Desktop Host Uninstaller".
                .sorted { $0.compactName.count < $1.compactName.count }.prefix(1)
                .map { Entry(compactName: spoken + written, app: $0.app) }
        }
        return candidates.max { $0.compactName.count < $1.compactName.count }?.app
    }
}
