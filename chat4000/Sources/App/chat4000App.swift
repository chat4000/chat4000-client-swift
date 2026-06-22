// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum AppScreen {
    case enterPairingCode
    case pairingConnecting
    case appConnecting
    case reconnecting
    case setup
    case connectedCelebration
    case chat
}

@main
struct chat4000App: App {
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @UIApplicationDelegateAdaptor(PlatformAppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(PlatformAppDelegate.self) private var appDelegate
    #endif

    @State private var chatViewModel: ChatViewModel
    @State private var currentScreen: AppScreen
    @State private var errorMessage: String?
    @State private var activeSessionStartedAt: Date?
    @State private var showLegalReconsentModal: Bool
    @State private var currentTermsVersion: Int?
    @State private var versionPolicy = VersionPolicyManager.shared
    #if os(macOS)
    @State private var macUpdater = MacUpdater.shared
    #endif
    @State private var founderPromptRequest: FounderChatPromptRequest?
    @State private var shouldCelebrateFirstConnection = false
    #if os(iOS)
    @State private var telemetryFlushBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    init() {
        let initialViewModel = ChatViewModel()

        _chatViewModel = State(initialValue: initialViewModel)
        // v2: route on the persisted Matrix session, not a v1 group key. A returning
        // user (already set up at least once) goes STRAIGHT to the chat — local rooms
        // and history restore from disk and the socket connects in the background, so
        // there's no full-screen "connecting" wall. Only a never-set-up pairing still
        // shows the first-run connecting screen.
        let initialScreen: AppScreen
        if initialViewModel.isPaired {
            initialScreen = initialViewModel.matrixSession.hasCompletedFirstSetup ? .chat : .appConnecting
        } else {
            initialScreen = .enterPairingCode
        }
        _currentScreen = State(initialValue: initialScreen)
        _showLegalReconsentModal = State(initialValue: false)
        _currentTermsVersion = State(initialValue: nil)

        // Silent-push wake (A1): drain via the live Matrix session — connect +
        // one sync — which posts local notifications for new messages while
        // backgrounded. Reuses the session's single OlmMachine (no second store).
        PushNotificationManager.shared.backgroundWakeHandler = { @MainActor in
            await initialViewModel.backgroundWake()
        }
        // Notification TAP → open the tapped room (F). Routed through the live
        // session, which opens immediately if loaded or defers to the next sync.
        PushNotificationManager.shared.openRoomHandler = { @MainActor roomId in
            initialViewModel.matrixSession.openRoomFromPush(roomId)
        }
        PushNotificationManager.shared.clearBadge()

        TelemetryManager.shared.configure(from: Self.loadDevConfig())
        IntercomService.startIfConfigured()
        Haptics.prime()
    }

    private static func loadDevConfig() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "dev-config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// Protocol C.5: check the registrar `/version` on every open and drive the
    /// terms-reconsent gate from `current_terms_version`.
    private func runVersionCheck() async {
        await versionPolicy.check()
        if let terms = versionPolicy.currentTermsVersion {
            LegalConsent.finalizePendingAcceptanceIfNeeded(currentTermsVersion: terms)
            currentTermsVersion = terms
            showLegalReconsentModal = LegalConsent.requiresReconsent(currentTermsVersion: terms)
        }
    }

    #if os(macOS)
    /// Drives the non-blocking "update ready" sheet. `get` defers to the
    /// updater's `shouldShowPopup` (verified-ready upgrade, not yet shown, not
    /// dismissed this session); dismissing the sheet records a session dismissal
    /// so it doesn't immediately re-present.
    private var macUpdatePopupBinding: Binding<Bool> {
        Binding(
            get: { macUpdater.shouldShowPopup },
            set: { presenting in
                if !presenting { macUpdater.dismissPopupForSession() }
            }
        )
    }
    #endif

    var body: some Scene {
        WindowGroup {
            Group {
                #if os(macOS)
                // macOS DMG self-update force (protocol C.5.3): the block screen
                // with the in-app install controls (auto-download behind it,
                // "Update Now" once verified). Takes precedence over the /version
                // force gate since it can actually self-install.
                if case .forced(let version) = macUpdater.state {
                    UpgradeRequiredView(
                        minVersion: nil,
                        recommended: version,
                        message: nil,
                        showMacInstallAction: true
                    )
                } else if case .forceUpgrade(let minV, let rec, let msg) = versionPolicy.action {
                    UpgradeRequiredView(minVersion: minV, recommended: rec, message: msg)
                } else {
                    primaryContent
                }
                #else
                if case .forceUpgrade(let minV, let rec, let msg) = versionPolicy.action {
                    UpgradeRequiredView(minVersion: minV, recommended: rec, message: msg)
                } else {
                    primaryContent
                }
                #endif
            }
            .background(ModelContextBinder(viewModel: chatViewModel))
            #if os(macOS)
            // Ctrl+Tab / Ctrl+Shift+Tab session cycling. A menu key-equivalent
            // can't claim Tab (macOS reserves it for focus traversal), so a
            // local NSEvent monitor intercepts it instead.
            .background(MacSessionKeyShortcuts { forward in
                guard currentScreen == .chat else { return false }
                chatViewModel.cycleActiveRoom(forward: forward)
                return true
            })
            #endif
            .onAppear {
                presentPendingFounderPromptIfPossible()
            }
            .task {
                await runVersionCheck()
                #if os(macOS)
                // Cold launch: kick off the DMG self-update check + hourly loop
                // (protocol C.5.3). Async / non-blocking.
                macUpdater.startScheduling()
                #endif
            }
            #if os(macOS)
            // Non-blocking "update ready" popup for a background-verified upgrade
            // (shown once per new version; the sidebar pill persists).
            .sheet(isPresented: macUpdatePopupBinding) {
                if let version = macUpdater.offeredVersion {
                    UpdateAvailablePopup(version: version)
                }
            }
            #endif
            .preferredColorScheme(.dark)
            #if os(macOS)
            .animation(.easeInOut(duration: 0.3), value: currentScreen)
            #endif
            .onChange(of: chatViewModel.connectionState) { _, newState in
                switch newState {
                case .connected:
                    errorMessage = nil
                    chatViewModel.refreshMessages()
                    routeAfterConnectionProgress()
                case .reconnecting:
                    // Reconnect silently (product decision): a transient socket drop
                    // shows NO visual anywhere — no full-screen takeover and no
                    // in-chat strip (see ChatView.connectionBanner). Whatever screen
                    // the user is on (chat, or a first-connect/setup screen) stays put
                    // while the socket layer reconnects and redrives queued sends. The
                    // `.reconnecting` AppScreen is consequently never entered.
                    break
                case .failed(let message):
                    // Pairing or restore failed — surface the error on the
                    // entry screen.
                    if currentScreen == .pairingConnecting
                        || currentScreen == .appConnecting
                        || currentScreen == .setup
                        || currentScreen == .reconnecting {
                        shouldCelebrateFirstConnection = false
                        errorMessage = message
                        Haptics.error()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentScreen = .enterPairingCode
                        }
                    }
                case .disconnected:
                    // Signed out / torn down — return to the entry screen.
                    if currentScreen == .chat
                        || currentScreen == .appConnecting
                        || currentScreen == .setup
                        || currentScreen == .reconnecting {
                        shouldCelebrateFirstConnection = false
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentScreen = .enterPairingCode
                        }
                    }
                default:
                    break
                }
            }
            .onChange(of: chatViewModel.setupPhase) { _, _ in
                guard chatViewModel.connectionState == .connected else { return }
                routeAfterConnectionProgress()
            }
            .onChange(of: scenePhase) { _, newPhase in
                // D.4: drive this device's foreground state from the scene phase.
                // Only `.active` (app frontmost) counts as active; `.inactive`
                // (incl. lock-while-frontmost, app switcher) and `.background`
                // are not. Combined with the device lock state inside the session
                // and reported to the gateway on every flip.
                //
                // iOS ONLY drives `appActive` from `scenePhase` here. On macOS the
                // scene phase does NOT reliably leave `.active` on app-switch for an
                // AppKit-backed app, so `appActive` is driven by AppKit's
                // application-active notifications inside MatrixSession instead;
                // calling `setAppActive` from here on macOS would fight that
                // authoritative source (a stale `.active` would re-mark a
                // deactivated app foreground). The rest of this handler (logging,
                // refresh, telemetry) still runs on both platforms.
                #if os(iOS)
                chatViewModel.matrixSession.setAppActive(newPhase == .active)
                #endif
                switch newPhase {
                case .active:
                    // Log the running version on every foreground (not just cold
                    // launch) so a pulled log always identifies the exact build,
                    // even when the app was only resumed.
                    AppLog.log("📲 foregrounded — chat4000 v%@ (build %@) env=%@",
                               AppRegistrationIdentity.currentAppVersion,
                               Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
                               MatrixEnvironment.isStage ? "stage" : "prod")
                    Haptics.prime()
                    activeSessionStartedAt = .now
                    chatViewModel.refreshMessages()
                    chatViewModel.matrixSession.clearNotificationsForActiveRoom()
                    if currentScreen == .chat, chatViewModel.isPaired {
                        Task { await chatViewModel.matrixSession.connect() }
                    }
                    Task { await runVersionCheck() }
                    #if os(macOS)
                    // Foreground-resume DMG self-update check (debounced).
                    macUpdater.checkOnForeground()
                    #endif
                    PushNotificationManager.shared.clearBadge()
                    // CL24 app_opened (CHANGED): push attribution + session count.
                    let opened = PushNotificationManager.consumeOpenSource()
                    var openedProps: [String: Any] = [
                        "source": opened.source,
                        "session_count": chatViewModel.matrixSession.rooms.count
                    ]
                    if let pushId = opened.pushId { openedProps["push_id"] = pushId }
                    TelemetryManager.shared.track(.appOpened, properties: openedProps)
                    presentPendingFounderPromptIfPossible()
                case .background:
                    // v2: leave the Matrix sync running; silent push + SDK
                    // sync drive background delivery. No socket teardown.
                    finishActiveSessionIfNeeded()
                default:
                    break
                }
            }
            // Custom scheme (chat4000://…) and, on some iOS versions, universal links.
            .onOpenURL { url in
                AppLog.log("🎯 onOpenURL %@", url.absoluteString)
                handleIncomingURL(url)
            }
            // Universal links (https://pair.chat4000.com/pair…) are delivered as a
            // browsing-web user activity.
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                guard let url = activity.webpageURL else { return }
                AppLog.log("🎯 universalLink %@", url.absoluteString)
                handleIncomingURL(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: PushNotificationManager.founderChatPromptRequested)) { _ in
                presentPendingFounderPromptIfPossible()
            }
            .sheet(isPresented: Binding(
                get: { founderPromptRequest != nil },
                set: { if !$0 { dismissFounderPromptAndDrainQueue() } }
            )) {
                if let founderPromptRequest {
                    FounderChatPromptModal(
                        source: founderPromptRequest.source,
                        modalTitle: founderPromptRequest.modalTitle ?? FounderChatPromptModal.defaultTitle,
                        modalBody: founderPromptRequest.modalBody ?? FounderChatPromptModal.defaultBody,
                        contactMessage: founderPromptRequest.contactMessage,
                        disableWhatsApp: founderPromptRequest.disableWhatsApp ?? false,
                        disableTelegram: founderPromptRequest.disableTelegram ?? false
                    )
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showLegalReconsentModal) {
                LegalReconsentModal(
                    currentTermsVersion: currentTermsVersion ?? LegalConsent.acceptedTermsVersion,
                    onAccept: {
                    showLegalReconsentModal = false
                    }
                )
                .interactiveDismissDisabled(true)
            }
            #elseif os(macOS)
            .sheet(isPresented: $showLegalReconsentModal) {
                LegalReconsentModal(
                    currentTermsVersion: currentTermsVersion ?? LegalConsent.acceptedTermsVersion,
                    onAccept: {
                    showLegalReconsentModal = false
                    }
                )
                .interactiveDismissDisabled(true)
            }
            #endif
            .onChange(of: showLegalReconsentModal) { _, isPresented in
                guard !isPresented else { return }
                presentPendingFounderPromptIfPossible()
            }
        }
        #if os(macOS)
        .windowResizability(.automatic)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .defaultSize(width: 950, height: 700)
        .commands {
            // REPLACE the WindowGroup's default "New Window" (Cmd+N) with
            // "New Session" — Cmd+N must create a session, not a new window.
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    guard currentScreen == .chat else { return }
                    chatViewModel.matrixSession.requestNewSession()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            // Ctrl+Tab / Ctrl+Shift+Tab → cycle through sessions, like browser
            // tabs. These also have a real key monitor (MacSessionKeyShortcuts)
            // because macOS reserves Tab for focus traversal and won't deliver
            // it to a menu key-equivalent; the menu items exist for discovery.
            CommandMenu("Sessions") {
                Button("Rename Session…") {
                    guard currentScreen == .chat else { return }
                    chatViewModel.matrixSession.requestRenameActiveSession()
                }
                .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Next Session") {
                    guard currentScreen == .chat else { return }
                    chatViewModel.cycleActiveRoom(forward: true)
                }
                .keyboardShortcut(.tab, modifiers: .control)
                Button("Previous Session") {
                    guard currentScreen == .chat else { return }
                    chatViewModel.cycleActiveRoom(forward: false)
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            }
        }
        #endif
        .modelContainer(for: [ChatMessage.self, MatrixRoomSnapshot.self])
    }

    private func presentPendingFounderPromptIfPossible() {
        guard founderPromptRequest == nil, !showLegalReconsentModal else { return }
        founderPromptRequest = FounderChatPromptStore.shared.consumePendingPrompt()
    }

    private func routeAfterConnectionProgress() {
        guard chatViewModel.connectionState == .connected else { return }
        if chatViewModel.showSetupProgress {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentScreen = .setup
            }
        } else if shouldCelebrateFirstConnection {
            showFirstConnectionCelebration()
        } else {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentScreen = .chat
            }
        }
    }

    private func showFirstConnectionCelebration() {
        guard currentScreen != .connectedCelebration else { return }
        shouldCelebrateFirstConnection = false
        Haptics.fanfare()
        withAnimation(.easeInOut(duration: 0.3)) {
            currentScreen = .connectedCelebration
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard currentScreen == .connectedCelebration else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                currentScreen = .chat
            }
        }
    }

    private func dismissFounderPromptAndDrainQueue() {
        founderPromptRequest = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            presentPendingFounderPromptIfPossible()
        }
    }

    @ViewBuilder
    private var primaryContent: some View {
        switch currentScreen {
        case .enterPairingCode:
            EnterPairingCodeView(
                errorMessage: errorMessage,
                onSubmit: startJoinPairing
            )

        case .pairingConnecting:
            ConnectingView(
                connectionState: chatViewModel.connectionState,
                onBack: {
                    chatViewModel.disconnect()
                    errorMessage = nil
                    shouldCelebrateFirstConnection = false
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentScreen = .enterPairingCode
                    }
                }
            )
            // Pairing (Task in startJoinPairing) is already in flight; this
            // screen just reflects connection state.

        case .appConnecting:
            Chat4000ConnectingScreen(connectionState: chatViewModel.connectionState)

        case .reconnecting:
            Chat4000ConnectingScreen(connectionState: .reconnecting)

        case .setup:
            SetupProgressScreen(
                phase: chatViewModel.setupPhase,
                stalled: chatViewModel.setupStalled,
                onRetry: { chatViewModel.retrySetupWait() },
                onStartOver: {
                    chatViewModel.disconnect()
                    errorMessage = nil
                    shouldCelebrateFirstConnection = false
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentScreen = .enterPairingCode
                    }
                }
            )

        case .connectedCelebration:
            ConnectedCelebrationScreen()

        case .chat:
            ChatShell(
                viewModel: chatViewModel,
                shouldConnect: true
            )
        }
    }

    private func finishActiveSessionIfNeeded() {
        guard let startedAt = activeSessionStartedAt else { return }

        let duration = Date().timeIntervalSince(startedAt)
        TelemetryManager.shared.track(
            .appClosed,
            properties: [
                "session_duration_seconds": Int(duration.rounded()),
                "session_duration_bucket": AnalyticsBuckets.sessionDurationBucket(for: duration)
            ]
        )
        TelemetryManager.shared.flush()
        activeSessionStartedAt = nil

        #if os(iOS)
        beginTelemetryFlushBackgroundTask()
        #endif
    }

    #if os(iOS)
    private func beginTelemetryFlushBackgroundTask() {
        endTelemetryFlushBackgroundTask()

        telemetryFlushBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "chat4000-posthog-flush") {
            endTelemetryFlushBackgroundTask()
        }

        guard telemetryFlushBackgroundTask != .invalid else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            endTelemetryFlushBackgroundTask()
        }
    }

    private func endTelemetryFlushBackgroundTask() {
        guard telemetryFlushBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(telemetryFlushBackgroundTask)
        telemetryFlushBackgroundTask = .invalid
    }
    #endif

    /// v2 pairing: the input is a provisioning pairing code (or a
    /// `chat4000://pair?code=…` URI). Redeem → `m.login.token` → Matrix client.
    /// Connection state drives routing (see `onChange(connectionState)`).
    /// Route an incoming URL (universal link or custom scheme). A `/pair?code=…`
    /// link starts pairing with that code via the SAME flow as manual entry; any
    /// other URL falls through to the launch-action store (record/compose) and is
    /// otherwise ignored silently. Never crashes on a malformed URL.
    private func handleIncomingURL(_ url: URL) {
        if let code = pairingCode(from: url) {
            TelemetryManager.shared.track(
                .pairingLinkOpened,
                properties: ["source": url.scheme?.lowercased() == "chat4000" ? "url_scheme" : "universal_link"]
            )
            startJoinPairing(code)
            return
        }
        if let action = LaunchActionStore.action(for: url) {
            LaunchActionStore.set(action)
        }
        // Any other path / malformed URL: ignore.
    }

    /// Returns the 6-digit pairing code IFF `url` is a pairing link —
    /// `https://pair.chat4000.com/pair?code=NNNNNN` or `chat4000://pair?code=NNNNNN`.
    /// Any other host/path/scheme, or a non-6-digit code, returns nil.
    private static let pairLinkHosts: Set<String> = ["pair.chat4000.com", "chat4000.com"]

    private func pairingCode(from url: URL) -> String? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let isPairLink: Bool
        switch comps.scheme?.lowercased() {
        case "https", "http":
            // Pairing links live on a dedicated host, so any path carrying a `code`
            // is a pair link — covers the QR form `https://pair.chat4000.com/?code=`
            // (root path) and the older `/pair?code=` alike.
            guard let host = comps.host?.lowercased(), Self.pairLinkHosts.contains(host) else { return nil }
            isPairLink = ["/", "", "/pair"].contains(comps.path.lowercased())
        case "chat4000":
            // chat4000://pair?code=… → host is "pair"; tolerate chat4000:///pair too.
            isPairLink = (comps.host?.lowercased() == "pair") || comps.path.lowercased() == "/pair"
        default:
            return nil
        }
        guard isPairLink,
              let raw = comps.queryItems?.first(where: { $0.name.lowercased() == "code" })?.value
        else { return nil }
        let digits = raw.filter(\.isNumber)
        return digits.count == 6 ? digits : nil
    }

    private func startJoinPairing(_ input: String) {
        if currentScreen == .pairingConnecting {
            AppLog.log("🔗 Ignoring duplicate pairing while already connecting")
            return
        }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a pairing code"
            Haptics.error()
            return
        }

        // v2 codes are 6 digits; the input may be a bare code or a
        // chat4000://pair?code=NNNNNN URI — extract the `code` param, don't
        // digit-filter the whole string ("chat4000" contributes 4000).
        let code = MatrixPairing.extractCode(from: trimmed)

        errorMessage = nil
        shouldCelebrateFirstConnection = true
        TelemetryManager.shared.track(.pairingCodeSubmitted, properties: ["input_type": "code"])
        TelemetryManager.shared.track(.pairingStarted, properties: ["flow": "matrix_join"])

        withAnimation(.easeInOut(duration: 0.3)) {
            currentScreen = .pairingConnecting
        }
        Task { await chatViewModel.pair(code: code) }
    }

}

#if os(macOS)
/// Installs a process-local key monitor for Ctrl+Tab (next) and Ctrl+Shift+Tab
/// (previous) session cycling. macOS reserves Tab for keyboard focus traversal
/// and never routes it to a SwiftUI menu key-equivalent, so we intercept the raw
/// key event. `onCycle(forward:)` returns true when it handled the key, in which
/// case the event is consumed (returned nil) so focus traversal doesn't also run.
private struct MacSessionKeyShortcuts: NSViewRepresentable {
    /// forward == true for next session (no Shift), false for previous (Shift).
    let onCycle: (_ forward: Bool) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onCycle = onCycle
        context.coordinator.install()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Keep the captured closure fresh so `currentScreen` is current.
        context.coordinator.onCycle = onCycle
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var onCycle: ((Bool) -> Bool)?
        private var monitor: Any?
        private static let tabKeyCode: UInt16 = 48

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      event.keyCode == Self.tabKeyCode,
                      event.modifierFlags.contains(.control)
                else { return event }
                let forward = !event.modifierFlags.contains(.shift)
                return (self.onCycle?(forward) == true) ? nil : event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif

private struct ModelContextBinder: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: ChatViewModel

    var body: some View {
        Color.clear
            .onAppear {
                viewModel.attach(modelContext: modelContext)
                if viewModel.isPaired {
                    viewModel.setupMatrix(modelContext: modelContext)
                }
            }
    }
}
