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
    case connecting
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
    #if os(iOS)
    @State private var telemetryFlushBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    init() {
        let initialViewModel = ChatViewModel()

        _chatViewModel = State(initialValue: initialViewModel)
        // v2: route on the persisted Matrix session, not a v1 group key.
        _currentScreen = State(initialValue: initialViewModel.isPaired ? .chat : .enterPairingCode)
        _showLegalReconsentModal = State(initialValue: false)
        _currentTermsVersion = State(initialValue: nil)

        // TODO(v2): background silent-push wake should drain via a short-lived
        // Matrix sync; the v1 relay-based wake service was removed.
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
    var body: some Scene {
        WindowGroup {
            Group {
                if case .hardBlock(let minVersion, let latestVersion) = versionPolicy.action {
                    UpgradeRequiredView(minVersion: minVersion, latestVersion: latestVersion)
                } else {
                    primaryContent
                }
            }
            .background(ModelContextBinder(viewModel: chatViewModel))
            .task {
                chatViewModel.onTermsVersionUpdate = { currentTermsVersion in
                    LegalConsent.finalizePendingAcceptanceIfNeeded(currentTermsVersion: currentTermsVersion)
                    self.currentTermsVersion = currentTermsVersion
                    self.showLegalReconsentModal = LegalConsent.requiresTermsAcceptance(currentTermsVersion: currentTermsVersion)
                }
            }
            .preferredColorScheme(.dark)
            #if os(macOS)
            .animation(.easeInOut(duration: 0.3), value: currentScreen)
            #endif
            .onChange(of: chatViewModel.connectionState) { _, newState in
                switch newState {
                case .connected:
                    errorMessage = nil
                    chatViewModel.refreshMessages()
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentScreen = .chat
                    }
                case .failed(let message):
                    // Pairing or restore failed — surface the error on the
                    // entry screen.
                    if currentScreen == .connecting {
                        errorMessage = message
                        Haptics.error()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentScreen = .enterPairingCode
                        }
                    }
                case .disconnected:
                    // Signed out / torn down — return to the entry screen.
                    if currentScreen == .chat {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentScreen = .enterPairingCode
                        }
                    }
                default:
                    break
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    Haptics.prime()
                    activeSessionStartedAt = .now
                    chatViewModel.refreshMessages()
                    if currentScreen == .chat, chatViewModel.isPaired {
                        Task { await chatViewModel.matrixSession.connect() }
                    }
                    PushNotificationManager.shared.clearBadge()
                    TelemetryManager.shared.track(.appOpened)
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
        }
        #if os(macOS)
        .windowResizability(.automatic)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .defaultSize(width: 950, height: 700)
        #endif
        .modelContainer(for: ChatMessage.self)
    }

    @ViewBuilder
    private var primaryContent: some View {
        switch currentScreen {
        case .enterPairingCode:
            EnterPairingCodeView(
                errorMessage: errorMessage,
                onSubmit: startJoinPairing
            )

        case .connecting:
            ConnectingView(
                connectionState: chatViewModel.connectionState,
                onBack: {
                    chatViewModel.disconnect()
                    errorMessage = nil
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentScreen = .enterPairingCode
                    }
                }
            )
            // Pairing (Task in startJoinPairing) is already in flight; this
            // screen just reflects connection state.

        case .chat:
            ChatShell(
                viewModel: chatViewModel,
                onAddDevice: startHostedPairing,
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
                "session_duration_bucket": AnalyticsBuckets.sessionDurationBucket(for: duration),
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
        if currentScreen == .connecting {
            AppLog.log("🔗 Ignoring duplicate pairing while already connecting")
            return
        }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a pairing code"
            Haptics.error()
            return
        }

        // Accept either a bare code or a chat4000://pair?code=… URI.
        let code = RelayCrypto.parsePairingURI(trimmed)?.code ?? trimmed

        errorMessage = nil
        TelemetryManager.shared.track(.pairingCodeSubmitted, properties: ["input_type": "code"])
        TelemetryManager.shared.track(.pairingStarted, properties: ["flow": "matrix_join"])

        withAnimation(.easeInOut(duration: 0.3)) {
            currentScreen = .connecting
        }
        Task { await chatViewModel.pair(code: code) }
    }

    /// v2 add-device uses the SDK's MSC4108 QR login (a logged-in device
    /// provisions the new one). Not wired yet.
    private func startHostedPairing() {
        AppLog.log("🔗 Add-device (MSC4108 QR login) not implemented in v2 yet")
        errorMessage = nil
    }

}

struct UpgradeRequiredView: View {
    let minVersion: String
    let latestVersion: String?

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white)

                Text("Update Required")
                    .font(AppFonts.title)
                    .foregroundStyle(AppColors.textPrimary)

                Text(message)
                    .font(AppFonts.subtitle)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Text(versionLine)
                    .font(AppFonts.caption)
                    .foregroundStyle(AppColors.textTimestamp)
            }
            .padding(24)
        }
    }

    private var message: String {
        "This version of chat4000 is no longer supported. Please update from the App Store to continue using chat4000."
    }

    private var versionLine: String {
        if let latestVersion {
            return "Minimum \(minVersion) · Latest \(latestVersion)"
        }
        return "Minimum \(minVersion)"
    }
}

struct UpgradeRecommendedBanner: View {
    let recommendedVersion: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Update available")
                    .font(AppFonts.label)
                    .foregroundStyle(AppColors.textPrimary)
                Text("Recommended version \(recommendedVersion)")
                    .font(AppFonts.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColors.cardBackground)
        .overlay(
            Rectangle()
                .fill(AppColors.inputBorder)
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

/// Per protocol §6.3 plugin_version_policy — soft nag banner shown when the
/// plugin running on the user's paired computer is below the recommended
/// version. Same visual treatment as `UpgradeRecommendedBanner` but with
/// copy that points at OpenClaw rather than the app itself.
struct PluginUpgradeRecommendedBanner: View {
    let recommendedVersion: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer.and.arrow.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Plugin update available")
                    .font(AppFonts.label)
                    .foregroundStyle(AppColors.textPrimary)
                Text("Update OpenClaw on your paired computer to \(recommendedVersion) or newer")
                    .font(AppFonts.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColors.cardBackground)
        .overlay(
            Rectangle()
                .fill(AppColors.inputBorder)
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

private struct ModelContextBinder: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: ChatViewModel

    var body: some View {
        Color.clear
            .onAppear {
                viewModel.attach(modelContext: modelContext)
            }
    }
}

