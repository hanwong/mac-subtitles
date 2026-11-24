import AppKit
import Combine
import SwiftUI

@main
struct HeyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(systemName: menuSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuSymbol: String {
        switch model.state {
        case .loading: return "ellipsis.circle"
        case .listening: return "mic"
        case .armed: return "mic.fill"
        case .failed: return "mic.slash"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var banner: BannerController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        banner = BannerController(model: .shared)
        // Media, lock and screenshot commands are sent as key presses, which macOS only allows with this permission.
        SystemController.ensureAccessibility()
        Task { await AppModel.shared.start() }
    }
}

/// The panel in the menu bar: status, settings and a reminder of what can be said.
struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @State private var accessibilityGranted = SystemController.ensureAccessibility(prompt: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(statusText, systemImage: statusSymbol)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if !model.heardText.isEmpty {
                Text("들은 말: \(model.heardText)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Button("지금 듣기 (호출어 없이)") { model.arm() }
                .disabled(model.state != .listening)

            if !accessibilityGranted {
                VStack(alignment: .leading, spacing: 4) {
                    Text("미디어 제어·화면 잠금·스크린샷은 손쉬운 사용 권한이 필요합니다.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("이미 켜져 있는데도 이 안내가 보이면, 앱을 새로 빌드해 서명이 바뀐 것입니다. 목록에서 Hey Mac을 −로 지운 뒤 다시 추가해 주세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("손쉬운 사용 설정 열기") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }

            Divider()
            LabeledContent("호출어") {
                TextField("쉼표로 구분", text: $model.wakeWords)
                    .textFieldStyle(.roundedBorder)
            }
            Picker("명령 언어", selection: $model.languageID) {
                ForEach(model.languages, id: \.id) { Text($0.name).tag($0.id) }
            }
            Toggle("효과음", isOn: $model.playsSounds)

            Divider()
            DisclosureGroup("말할 수 있는 명령") {
                Text(Self.examples)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }

            Divider()
            Button("Hey Mac 종료") { NSApp.terminate(nil) }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { accessibilityGranted = SystemController.ensureAccessibility(prompt: false) }
    }

    private var statusText: String {
        switch model.state {
        case .loading(let message): return message
        case .listening: return "\"\(model.wakeWords.split(separator: ",").first.map(String.init) ?? "")\"(이)라고 불러 주세요"
        case .armed: return "듣고 있어요…"
        case .failed(let message): return message
        }
    }

    private var statusSymbol: String {
        switch model.state {
        case .loading: return "ellipsis.circle"
        case .listening: return "mic"
        case .armed: return "waveform"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private static let examples = """
        음량: "볼륨 올려줘", "볼륨 30으로", "음소거"
        밝기: "화면 밝게", "밝기 70으로"
        미디어: "일시정지", "재생", "다음 곡", "앞으로 감아줘"
        전원: "잠자기", "화면 꺼줘", "화면 잠가줘"
        앱: "사파리 열어줘", "크롬 종료해줘"
        기타: "다크 모드 켜줘", "스크린샷 찍어줘"
        """
}

/// A click-through banner at the top of the screen that confirms what was heard and done.
@MainActor
final class BannerController {
    private let panel: NSPanel
    private var subscription: AnyCancellable?

    init(model: AppModel) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: BannerView().environmentObject(model))

        subscription = model.$banner.sink { [weak self] banner in
            self?.update(visible: banner != nil)
        }
    }

    private func update(visible: Bool) {
        guard visible, let screen = NSScreen.main ?? NSScreen.screens.first else {
            panel.orderOut(nil)
            return
        }
        let area = screen.visibleFrame
        let size = NSSize(width: min(640, area.width * 0.8), height: 90)
        panel.setFrame(
            NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height - 12, width: size.width, height: size.height),
            display: true)
        panel.orderFrontRegardless()
    }
}

struct BannerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack {
            if let banner = model.banner {
                Label(banner.text, systemImage: symbol(for: banner.kind))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(color(for: banner.kind).opacity(0.9), in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func symbol(for kind: AppModel.Banner.Kind) -> String {
        switch kind {
        case .listening: return "waveform"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for kind: AppModel.Banner.Kind) -> Color {
        switch kind {
        case .listening: return .blue
        case .done: return .black
        case .failed: return .red
        }
    }
}
