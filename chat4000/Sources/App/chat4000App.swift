// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
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
    @State private var founderPromptRequest: FounderChatPromptRequest?
    @State private var shouldCelebrateFirstConnection = false
    #if os(iOS)
    @State private var telemetryFlushBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    init() {
        let initialViewModel = ChatViewModel()

        _chatViewModel = State(initialValue: initialViewModel)
        // v2: route on the persisted Matrix session, not a v1 group key.
        _currentScreen = State(initialValue: initialViewModel.isPaired ? .appConnecting : .enterPairingCode)
        _showLegalReconsentModal = State(initialValue: false)
        _currentTermsVersion = State(initialValue: nil)

        // Silent-push wake (A1): drain via the live Matrix session — connect +
        // one sync — which posts local notifications for new messages while
        // backgrounded. Reuses the session's single OlmMachine (no second store).
        PushNotificationManager.shared.backgroundWakeHandler = { @MainActor in
            await initialViewModel.backgroundWake()
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
            showLegalReconsentModal = LegalConsent.requiresTermsAcceptance(currentTermsVersion: terms)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if case .forceUpgrade(let minV, let rec, let msg) = versionPolicy.action {
                    UpgradeRequiredView(minVersion: minV, recommended: rec, message: msg)
                } else {
                    primaryContent
                }
            }
            .background(ModelContextBinder(viewModel: chatViewModel))
            .onAppear {
                presentPendingFounderPromptIfPossible()
            }
            .task { await runVersionCheck() }
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
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentScreen = .reconnecting
                    }
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
                    PushNotificationManager.shared.clearBadge()
                    TelemetryManager.shared.track(.appOpened)
                    presentPendingFounderPromptIfPossible()
                case .background:
                    // v2: leave the Matrix sync running; silent push + SDK
                    // sync drive background delivery. No socket teardown.
                    finishActiveSessionIfNeeded()
                default:
                    break
                }
            }
            .onOpenURL { url in
                AppLog.log("🎯 onOpenURL %@", url.absoluteString)
                guard let action = LaunchActionStore.action(for: url) else { return }
                LaunchActionStore.set(action)
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
                        modalBody: founderPromptRequest.modalBody ?? FounderChatPromptModal.defaultBody
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
