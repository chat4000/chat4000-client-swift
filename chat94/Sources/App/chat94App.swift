// chat94
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#endif

enum AppScreen {
    case enterPairingCode
    case pairing
    case connecting
    case chat
}

@main
struct chat94App: App {
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @UIApplicationDelegateAdaptor(PlatformAppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(PlatformAppDelegate.self) private var appDelegate
    #endif

    @State private var chatViewModel: ChatViewModel
    @State private var pairingCoordinator = PairingCoordinator()
    @State private var currentScreen: AppScreen
    @State private var groupConfig: GroupConfig?
    @State private var errorMessage: String?
    @State private var returnToChatAfterPairing = false
    @State private var activeSessionStartedAt: Date?
    @State private var showLegalReconsentModal: Bool
    @State private var currentTermsVersion: Int?
    @State private var versionPolicy = VersionPolicyManager.shared
    #if os(iOS)
    @State private var telemetryFlushBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    init() {
        let savedConfig = KeychainService.load()
        let initialViewModel = ChatViewModel()
        initialViewModel.config = savedConfig

        _chatViewModel = State(initialValue: initialViewModel)
        _groupConfig = State(initialValue: savedConfig)
        _currentScreen = State(initialValue: savedConfig == nil ? .enterPairingCode : .chat)
        _showLegalReconsentModal = State(initialValue: false)
        _currentTermsVersion = State(initialValue: nil)

        PushNotificationManager.shared.backgroundWakeHandler = {
            await BackgroundRelayWakeService.shared.handleSilentPush()
        }

        TelemetryManager.shared.configure(from: Self.loadDevConfig())
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
                    chatViewModel.refreshMessages()
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentScreen = .chat
                    }
                case .disconnected:
                    if currentScreen == .chat, groupConfig == nil {
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
                    TelemetryManager.shared.track(.appOpened)
                case .background:
                    finishActiveSessionIfNeeded()
                default:
                    break
                }
            }
            .onChange(of: chatViewModel.config) { _, newConfig in
                if newConfig == nil {
                    DevLog.log("🔗 App observed chatViewModel.config=nil on screen \(String(describing: currentScreen))")
                    groupConfig = nil
                    if currentScreen != .pairing {
                        pairingCoordinator.reset()
                    }
                    returnToChatAfterPairing = false
                    if currentScreen != .pairing {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentScreen = .enterPairingCode
                        }
                    }
                }
            }
            .onChange(of: pairingCoordinator.completedConfig) { _, newConfig in
                guard let newConfig else { return }
                returnToChatAfterPairing = false
                saveAndConnect(newConfig)
            }
            .onChange(of: pairingCoordinator.phase) { _, newPhase in
                switch newPhase {
                case .complete:
                    if let flow = pairingCoordinator.flow {
                        TelemetryManager.shared.track(
                            .pairingCompleted,
                            properties: ["flow": flow.rawValue]
                        )
                    }
                case .failed(let reason):
                    if let flow = pairingCoordinator.flow {
                        TelemetryManager.shared.track(
                            .pairingFailed,
                            properties: [
                                "flow": flow.rawValue,
                                "reason": reason,
                            ]
                        )
                    }
                default:
                    break
                }

                guard returnToChatAfterPairing else { return }
                if case .complete = newPhase {
                    pairingCoordinator.reset()
                    returnToChatAfterPairing = false
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentScreen = .chat
                    }
                }
            }
            .onOpenURL { url in
                DevLog.log("🎯 onOpenURL %@", url.absoluteString)
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

        case .pairing:
            PairingProgressView(
                coordinator: pairingCoordinator,
                onCancel: cancelPairing
            )

        case .connecting:
            ConnectingView(
                connectionState: chatViewModel.connectionState,
                onBack: {
                    chatViewModel.disconnect()
                    groupConfig = nil
                    errorMessage = nil
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentScreen = .enterPairingCode
                    }
                }
            )
            .onAppear {
                if let groupConfig {
                    chatViewModel.startConnection(config: groupConfig)
                }
            }

        case .chat:
            ChatViewWrapper(
                viewModel: chatViewModel,
                onAddDevice: startHostedPairing,
                shouldConnect: true
            )
        }
    }

    private func saveAndConnect(_ config: GroupConfig) {
        guard config.isValid else {
            errorMessage = "Enter a valid 32-byte group key"
            Haptics.error()
            return
        }

        guard let groupKey = config.groupKey else {
            errorMessage = "Enter a valid 32-byte group key"
            Haptics.error()
            return
        }

        let scopedConfig = GroupConfig(groupKey: groupKey)

        do {
            try KeychainService.save(scopedConfig)
        } catch {
            errorMessage = "Failed to save group key"
            Haptics.error()
            return
        }

        groupConfig = scopedConfig
        chatViewModel.config = scopedConfig
        errorMessage = nil
        Haptics.success()

        withAnimation(.easeInOut(duration: 0.3)) {
            currentScreen = .chat
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

        telemetryFlushBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "chat94-posthog-flush") {
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

    private func startJoinPairing(_ input: String) {
        DevLog.log("🔗 App startJoinPairing input=\(input) currentScreen=\(String(describing: currentScreen))")
        if currentScreen == .pairing {
            DevLog.log("🔗 Ignoring duplicate startJoinPairing while already pairing")
            return
        }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = RelayCrypto.normalizePairingCode(trimmed)
        DevLog.log("🔗 App startJoinPairing trimmed=\(trimmed) normalized=\(normalized)")

        if let invite = RelayCrypto.parsePairingURI(trimmed) {
            DevLog.log("🔗 App startJoinPairing taking pairing-uri path")
            TelemetryManager.shared.track(
                .pairingCodeSubmitted,
                properties: ["input_type": "uri"]
            )
            TelemetryManager.shared.track(
                .pairingStarted,
                properties: ["flow": PairingCoordinator.Flow.join.rawValue]
            )
            errorMessage = nil
            pairingCoordinator.join(code: invite.code)
            withAnimation(.easeInOut(duration: 0.3)) {
                currentScreen = .pairing
            }
            return
        }

        if normalized.count == 8, trimmed == normalized {
            DevLog.log("🔗 App startJoinPairing taking pairing-code path")
            TelemetryManager.shared.track(
                .pairingCodeSubmitted,
                properties: ["input_type": "code"]
            )
            TelemetryManager.shared.track(
                .pairingStarted,
                properties: ["flow": PairingCoordinator.Flow.join.rawValue]
            )
            errorMessage = nil
            pairingCoordinator.join(code: normalized)
            withAnimation(.easeInOut(duration: 0.3)) {
                currentScreen = .pairing
            }
            return
        }

        if let config = GroupConfig.parse(trimmed) {
            DevLog.log("🔗 App startJoinPairing taking direct-config path")
            TelemetryManager.shared.track(
                .pairingCodeSubmitted,
                properties: ["input_type": "direct_config"]
            )
            errorMessage = nil
            saveAndConnect(config)
            return
        }

        DevLog.log("🔗 App startJoinPairing invalid input")
        errorMessage = "Enter a valid pairing code or group key"
        Haptics.error()
    }

    private func startHostedPairing() {
        guard let groupConfig else { return }
        TelemetryManager.shared.track(.addDeviceFlowStarted)
        TelemetryManager.shared.track(
            .pairingStarted,
            properties: ["flow": PairingCoordinator.Flow.hostedAddDevice.rawValue]
        )
        errorMessage = nil
        returnToChatAfterPairing = true
        pairingCoordinator.startHosting(config: groupConfig)
        withAnimation(.easeInOut(duration: 0.3)) {
            currentScreen = .pairing
        }
    }

    private func cancelPairing() {
        pairingCoordinator.reset()
        errorMessage = nil
        withAnimation(.easeInOut(duration: 0.3)) {
            currentScreen = groupConfig == nil ? .enterPairingCode : .chat
        }
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
        "This version of chat94 is no longer supported. Please update from the App Store to continue using chat."
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

struct ChatViewWrapper: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: ChatViewModel
    var onAddDevice: () -> Void
    var shouldConnect: Bool

    var body: some View {
        ChatView(viewModel: viewModel, onAddDevice: onAddDevice)
            .onAppear {
                if shouldConnect, let config = viewModel.config {
                    viewModel.setup(modelContext: modelContext, config: config)
                }
            }
            .onChange(of: shouldConnect) { _, newValue in
                guard newValue, let config = viewModel.config else { return }
                viewModel.setup(modelContext: modelContext, config: config)
            }
    }
}
