#if os(macOS)
import SwiftUI
import AppKit

/// Standalone macOS window that hosts the Intercom web messenger.
/// Opens via a real `NSWindow` rather than a SwiftUI sheet — this side-
/// steps the "sheet-over-sheet" problem (Settings already owns the
/// presentation slot when the user taps the button from inside Settings).
/// Singleton so reopening focuses the existing window instead of stacking.
@MainActor
final class IntercomMacWindowController {
    static let shared = IntercomMacWindowController()

    private var window: NSWindow?

    private init() {}

    func present(source: String) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            AppLog.log("💬 [intercom] focusing existing mac window source=%@", source)
            return
        }

        let bridge = IntercomMacBridge(source: source)
        let root = IntercomMacWindowContent(bridge: bridge) { [weak self] in
            self?.window?.close()
        }

        let hosting = NSHostingController(rootView: root)
        let nsWindow = NSWindow(contentViewController: hosting)
        nsWindow.title = "Chat with founder"
        nsWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        nsWindow.setContentSize(NSSize(width: 460, height: 640))
        nsWindow.minSize = NSSize(width: 380, height: 480)
        nsWindow.isReleasedWhenClosed = false
        nsWindow.center()

        let observer = WindowCloseObserver { [weak self] in
            self?.window = nil
            self?.closeObserver = nil
        }
        observer.attach(to: nsWindow)
        closeObserver = observer

        window = nsWindow
        nsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        AppLog.log("💬 [intercom] presented new mac window source=%@", source)
    }

    private var closeObserver: WindowCloseObserver?
}

private final class WindowCloseObserver: NSObject {
    private let onClose: () -> Void
    private var token: NSObjectProtocol?

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func attach(to window: NSWindow) {
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.onClose()
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

/// The SwiftUI content displayed inside the standalone Intercom window.
private struct IntercomMacWindowContent: View {
    @ObservedObject var bridge: IntercomMacBridge
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            IntercomMacWebView(bridge: bridge)
                .frame(minWidth: 380, minHeight: 480)
        }
        .background(AppColors.background)
    }
}

#endif
