import AppKit
import SwiftUI

@main
struct LiveSubtitlesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Live Subtitles", id: "main") {
            ControlView().environmentObject(AppModel.shared)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlay: OverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay = OverlayController(model: .shared)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// A transparent, click-through panel pinned to the bottom of the main screen,
/// above every other window and visible on all Spaces, including full-screen apps.
@MainActor
final class OverlayController {
    private static let widthFraction = 0.8
    private static let height: CGFloat = 320
    private static let bottomMargin: CGFloat = 24

    private let panel: NSPanel

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
        panel.contentView = NSHostingView(rootView: SubtitleView().environmentObject(model))

        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    private func layout() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        let width = area.width * Self.widthFraction
        panel.setFrame(
            NSRect(x: area.midX - width / 2, y: area.minY + Self.bottomMargin, width: width, height: Self.height),
            display: true
        )
    }
}
