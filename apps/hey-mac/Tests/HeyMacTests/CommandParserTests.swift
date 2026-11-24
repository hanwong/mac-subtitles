import XCTest

@testable import HeyMac

final class CommandParserTests: XCTestCase {
    private let wakeWords = ["헤이 맥", "hey mac"]

    func testWakeWord() {
        XCTAssertEqual(CommandParser.textAfterWakeWord(in: "헤이 맥, 볼륨 올려줘.", wakeWords: wakeWords), "볼륨올려줘")
        XCTAssertEqual(CommandParser.textAfterWakeWord(in: "Hey Mac!", wakeWords: wakeWords), "")
        XCTAssertEqual(CommandParser.textAfterWakeWord(in: "음 헤이맥 잠자기", wakeWords: wakeWords), "잠자기")
        XCTAssertNil(CommandParser.textAfterWakeWord(in: "볼륨 올려줘", wakeWords: wakeWords))
        XCTAssertNil(CommandParser.textAfterWakeWord(in: "볼륨 올려줘", wakeWords: ["", " "]))
    }

    func testVolume() {
        XCTAssertEqual(CommandParser.parse("볼륨 올려 줘"), .changeVolume(10))
        XCTAssertEqual(CommandParser.parse("소리 좀 줄여줘"), .changeVolume(-10))
        XCTAssertEqual(CommandParser.parse("볼륨 50%로 해줘"), .setVolume(50))
        XCTAssertEqual(CommandParser.parse("볼륨 20 올려줘"), .changeVolume(20))
        XCTAssertEqual(CommandParser.parse("음량 최대로"), .setVolume(100))
        XCTAssertEqual(CommandParser.parse("Volume down"), .changeVolume(-10))
        XCTAssertEqual(CommandParser.parse("Set the volume to 30"), .setVolume(30))
        XCTAssertEqual(CommandParser.parse("음소거 해줘"), .setMuted(true))
        XCTAssertEqual(CommandParser.parse("소리 꺼줘"), .setMuted(true))
        XCTAssertEqual(CommandParser.parse("음소거 해제"), .setMuted(false))
        XCTAssertEqual(CommandParser.parse("소리 켜줘"), .setMuted(false))
        XCTAssertEqual(CommandParser.parse("unmute"), .setMuted(false))
    }

    func testBrightness() {
        XCTAssertEqual(CommandParser.parse("화면 밝기 올려줘"), .changeBrightness(10))
        XCTAssertEqual(CommandParser.parse("화면 좀 어둡게 해줘"), .changeBrightness(-10))
        XCTAssertEqual(CommandParser.parse("밝기 70으로"), .setBrightness(70))
        XCTAssertEqual(CommandParser.parse("Brightness up"), .changeBrightness(10))
        XCTAssertEqual(CommandParser.parse("make the screen dimmer"), .changeBrightness(-10))
    }

    func testPower() {
        XCTAssertEqual(CommandParser.parse("잠자기 모드로 해줘"), .sleep)
        XCTAssertEqual(CommandParser.parse("슬립 모드"), .sleep)
        XCTAssertEqual(CommandParser.parse("Go to sleep"), .sleep)
        XCTAssertEqual(CommandParser.parse("화면 꺼줘"), .sleepDisplay)
        XCTAssertEqual(CommandParser.parse("display sleep"), .sleepDisplay)
        XCTAssertEqual(CommandParser.parse("화면 잠가줘"), .lockScreen)
        XCTAssertEqual(CommandParser.parse("Lock the screen"), .lockScreen)
    }

    func testMedia() {
        XCTAssertEqual(CommandParser.parse("일시정지"), .playPause)
        XCTAssertEqual(CommandParser.parse("영상 재생해줘"), .playPause)
        XCTAssertEqual(CommandParser.parse("pause the video"), .playPause)
        XCTAssertEqual(CommandParser.parse("다음 곡"), .nextTrack)
        XCTAssertEqual(CommandParser.parse("이전 곡으로"), .previousTrack)
        XCTAssertEqual(CommandParser.parse("앞으로 감아줘"), .seek(forward: true))
        XCTAssertEqual(CommandParser.parse("뒤로 조금만"), .seek(forward: false))
    }

    func testOther() {
        XCTAssertEqual(CommandParser.parse("다크 모드 켜줘"), .setDarkMode(true))
        XCTAssertEqual(CommandParser.parse("다크모드 꺼줘"), .setDarkMode(false))
        XCTAssertEqual(CommandParser.parse("라이트 모드로 바꿔줘"), .setDarkMode(false))
        XCTAssertEqual(CommandParser.parse("스크린샷 찍어줘"), .screenshot)
        XCTAssertEqual(CommandParser.parse("사파리 열어줘"), .openApp("사파리열어줘"))
        XCTAssertEqual(CommandParser.parse("Open Clock"), .openApp("openclock"))
        XCTAssertEqual(CommandParser.parse("사파리 종료해줘"), .quitApp("사파리종료해줘"))
        XCTAssertNil(CommandParser.parse("오늘 날씨 어때"))
    }
}

extension CommandParserTests {
    func testLongestWakeWordWins() {
        let words = ["헤이 맥", "헤이 맥북"]
        XCTAssertEqual(CommandParser.textAfterWakeWord(in: "헤이 맥북 잠자기", wakeWords: words), "잠자기")
    }
}

extension CommandParserTests {
    func testMisheardWakeWord() {
        XCTAssertEqual(CommandParser.textAfterWakeWord(in: "해이 맥 볼륨 올려줘", wakeWords: ["헤이 맥"]), "볼륨올려줘")
        XCTAssertEqual(CommandParser.textAfterWakeWord(in: "헤이 멕, 일시정지", wakeWords: ["헤이 맥"]), "일시정지")
        XCTAssertEqual(CommandParser.textAfterWakeWord(in: "에이 맥 잠자기", wakeWords: ["헤이 맥"]), "잠자기")
        XCTAssertEqual(CommandParser.textAfterWakeWord(in: "Hey Mark, pause", wakeWords: ["hey mac"]), "pause")
        // Too far off, or not at the start.
        XCTAssertNil(CommandParser.textAfterWakeWord(in: "오늘 날씨 어때", wakeWords: ["헤이 맥"]))
        XCTAssertNil(CommandParser.textAfterWakeWord(in: "볼륨 올려줘 해이 맥", wakeWords: ["헤이 맥"]))
        XCTAssertNil(CommandParser.textAfterWakeWord(in: "헬로 맥스", wakeWords: ["헤이 맥"]))
    }
}
