import SwiftUI
import Sentry
import CoreImage.CIFilterBuiltins
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SettingsSheet: View {
    private let sentryGestureWindow: TimeInterval = 5.0
    private let secretTapThreshold = 15

    @Environment(\.dismiss) private var dismiss

    @Bindable var matrixSession: MatrixSession
    let pluginVersion: String?
    let pluginBundleId: String?
    var onDisconnect: () -> Void
    /// Optional: ask the paired plugin to update itself (protocol E). Any
    /// control-room member may run it — there's no separate owner role; the
    /// plugin gates on control-room membership. Fire-and-forget.
    var onUpdatePlugin: (() -> Void)?
    /// Close the panel. Used instead of `@Environment(\.dismiss)` so this view
    /// works both as an iOS sheet AND as a macOS overlay (where `dismiss()` is a
    /// no-op). The macOS overlay also dismisses on an outside click.
    var onClose: () -> Void = {}

    @State private var sentryResultMessage: String?
    @State private var showSentryResult = false
    @State private var addDeviceTapCount = 0
    @State private var addDeviceTapStartedAt: Date?
    @State private var groupIDTapCount = 0
    @State private var groupIDTapStartedAt: Date?
    @State private var privacyTapCount = 0
    @State private var privacyTapStartedAt: Date?
    @State private var pluginVersionTapCount = 0
    @State private var pluginVersionTapStartedAt: Date?
    @State private var isCollectionEnabled = TelemetryPreferences.isCollectionEnabled
    @State private var showFounderPromptTest = false
    @State private var diagnosticStatusMessage: String?
    @State private var showDiagnosticAlert = false
    @State private var showAddDeviceInfo = false
    @State private var showConfettiLab = false   // TEMPORARY — confetti comparison harness
    @State private var showHapticsLab = false    // TEMPORARY — haptics picker

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Text("Settings")
                        .font(AppFonts.sheetTitle)
                        .foregroundStyle(AppColors.textPrimary)
                        // Hidden QA gesture (moved here from the removed Account row):
                        // 15 taps triggers the Sentry crash-verification crash.
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleGroupIDGesture()
                        }

                    Spacer()

                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(width: 32, height: 32)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)

                Divider()
                    .background(AppColors.inputBorder)

                VStack(spacing: 20) {
                    deviceSection
                    telemetrySection

                    // TEMPORARY — confetti comparison harness. Delete this button +
                    // the cover + ConfettiLab.swift + the 3 SPM packages once picked.
                    Button {
                        showConfettiLab = true
                    } label: {
                        Text("🎊 Confetti Lab (temp)")
                            .font(AppFonts.button)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.button))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    // fullScreenCover is iOS-only; sheet on macOS keeps both building.
                    #if os(iOS)
                    .fullScreenCover(isPresented: $showConfettiLab) {
                        ConfettiLabView()
                    }
                    #else
                    .sheet(isPresented: $showConfettiLab) {
                        ConfettiLabView()
                    }
                    #endif

                    // TEMPORARY — haptics picker. Delete this button + the cover +
                    // HapticsLab.swift once a vibration is picked.
                    Button {
                        showHapticsLab = true
                    } label: {
                        Text("📳 Haptics Lab (temp)")
                            .font(AppFonts.button)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.button))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    #if os(iOS)
                    .fullScreenCover(isPresented: $showHapticsLab) {
                        HapticsLabView()
                    }
                    #else
                    .sheet(isPresented: $showHapticsLab) {
                        HapticsLabView()
                    }
                    #endif

                    Button {
                        onDisconnect()
                        onClose()
                    } label: {
                        Text("Disconnect")
                            .font(AppFonts.button)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.button))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)

                    VStack(spacing: 12) {
                        Text("Need help, or just want to say hi?")
                            .font(AppFonts.caption)
                            .foregroundStyle(AppColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)

                        ChatWithFounderButton(source: "settings")
                        JoinTelegramCommunityButton(source: "settings")
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                HStack(spacing: 0) {
                    Text("chat4000 v\(AppRegistrationIdentity.currentAppVersion)")
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleAddAnotherDeviceGesture()
                        }

                    if let pluginVersion, !pluginVersion.isEmpty {
                        Text(" · plugin v\(pluginVersion)")
                            .contentShape(Rectangle())
                            .onTapGesture {
                                handlePluginVersionGesture()
                            }
                    }
                }
                .font(AppFonts.caption)
                .foregroundStyle(AppColors.textTimestamp)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            "Sentry",
            isPresented: $showSentryResult
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sentryResultMessage ?? "Done.")
        }
        .sheet(isPresented: $showFounderPromptTest) {
            FounderChatPromptModal(source: "settings_10tap_test")
        }
        // iOS: full-screen cover (the sheet has its own X/Done dismiss). macOS:
        // keep a sized sheet. fullScreenCover is iOS-only, so guard it.
        #if os(iOS)
        .fullScreenCover(isPresented: $showAddDeviceInfo) {
            AddDevicePairingSheet(session: matrixSession)
        }
        #else
        .sheet(isPresented: $showAddDeviceInfo) {
            AddDevicePairingSheet(session: matrixSession)
                .presentationDetents([.height(470)])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppColors.cardBackground)
        }
        #endif
        .alert(
            "Diagnostics",
            isPresented: $showDiagnosticAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(diagnosticStatusMessage ?? "Sending diagnostics…")
        }
        .onReceive(NotificationCenter.default.publisher(for: DiagnosticReportService.statusChanged)) { note in
            guard let status = note.object as? DiagnosticReportService.Status else { return }
            switch status {
            case .succeeded:
                diagnosticStatusMessage = "Thanks for sending diagnostics! Our devs will start working on it immediately."
                showDiagnosticAlert = true
            case .failed(let reason):
                diagnosticStatusMessage = "Couldn't send diagnostics: \(reason). Please try again."
                showDiagnosticAlert = true
            default:
                break
            }
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Devices")
                .font(AppFonts.sectionTitle)
                .foregroundStyle(AppColors.textSecondary)

            VStack(alignment: .leading, spacing: 16) {
                Button {
                    showAddDeviceInfo = true
                } label: {
                    Text("Add Device")
                        .font(AppFonts.button)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.button))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(AppColors.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.input))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.input)
                    .stroke(AppColors.inputBorder, lineWidth: 1)
            )
        }
    }

    private var telemetrySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Privacy")
                .font(AppFonts.sectionTitle)
                .foregroundStyle(AppColors.textSecondary)
                .contentShape(Rectangle())
                .onTapGesture {
                    handlePrivacyGesture()
                }

            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { isCollectionEnabled },
                    set: { newValue in
                        isCollectionEnabled = newValue
                        TelemetryManager.shared.setCollectionEnabled(newValue)
                    }
                )) {
                    Text("Share diagnostics and analytics")
                        .font(AppFonts.body)
                        .foregroundStyle(AppColors.textPrimary)
                }
                .toggleStyle(.switch)
            }
            .padding(16)
            .background(AppColors.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.input))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.input)
                    .stroke(AppColors.inputBorder, lineWidth: 1)
            )
        }
    }

    private var versionFooter: String {
        let appPart = "chat4000 v\(AppRegistrationIdentity.currentAppVersion)"
        if let pluginVersion, !pluginVersion.isEmpty {
            return "\(appPart) · plugin v\(pluginVersion)"
        }
        return appPart
    }

    private func sendHandledSentryException() {
        SentrySDK.addBreadcrumb({
            let crumb = Breadcrumb()
            crumb.level = .info
            crumb.category = "qa.sentry"
            crumb.message = "Preparing hidden handled Sentry test exception"
            return crumb
        }())

        do {
            try performNestedSentryThrow()
        } catch {
            let eventId = captureHandledExceptionEvent(error: error)
            sentryResultMessage = "Sent handled exception to Sentry.\nEvent ID: \(eventId.sentryIdString)"
            showSentryResult = true
        }
    }

    private func captureHandledExceptionEvent(error: Error) -> SentryId {
        let event = Event(level: .error)
        let exception = Exception(
            value: error.localizedDescription,
            type: String(describing: type(of: error))
        )
        let mechanism = Mechanism(type: "generic")
        mechanism.handled = true
        exception.mechanism = mechanism
        exception.stacktrace = currentSentryStacktrace()
        event.exceptions = [exception]

        return SentrySDK.capture(event: event) { scope in
            scope.setTag(value: "settings_hidden_test", key: "source")
            scope.setTag(value: "handled_exception", key: "test_type")
            scope.setContext(value: [
                "bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
                "user_id": matrixSession.userId ?? "none"
            ], key: "hidden_test")
            scope.setExtra(value: String(reflecting: error), key: "error_reflection")
        }
    }

    private func currentSentryStacktrace() -> SentryStacktrace {
        let bundleName = Bundle.main.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
        let frames = Thread.callStackSymbols.map { symbol -> Frame in
            let frame = Frame()
            frame.function = symbol
            if let bundleName {
                frame.inApp = NSNumber(value: symbol.contains(bundleName))
            }
            return frame
        }
        return SentryStacktrace(frames: frames, registers: [:])
    }

    // EXEMPT: QA harness whose purpose is to throw a RAW error into Sentry — typing it as AppError would defeat the test.
    private func performNestedSentryThrow() throws {
        try sentryThrowLevelOne()
    }

    // EXEMPT: QA harness whose purpose is to throw a RAW error into Sentry — typing it as AppError would defeat the test.
    private func sentryThrowLevelOne() throws {
        try sentryThrowLevelTwo()
    }

    // EXEMPT: QA harness whose purpose is to throw a RAW error into Sentry — typing it as AppError would defeat the test.
    private func sentryThrowLevelTwo() throws {
        throw SentryDevTestError.simulatedFailure
    }

    private func triggerSentryCrash() {
        SentrySDK.addBreadcrumb({
            let crumb = Breadcrumb()
            crumb.level = .fatal
            crumb.category = "qa.sentry"
            crumb.message = "Triggering hidden crash for Sentry verification"
            return crumb
        }())
        fatalError("Sentry hidden crash test")
    }

    private func handleAddAnotherDeviceGesture() {
        let nextCount = nextTapCount(
            currentCount: addDeviceTapCount,
            startedAt: addDeviceTapStartedAt
        )
        addDeviceTapCount = nextCount.count
        addDeviceTapStartedAt = nextCount.startedAt

        guard addDeviceTapCount >= secretTapThreshold else { return }
        addDeviceTapCount = 0
        addDeviceTapStartedAt = nil
        sendHandledSentryException()
    }

    private func handleGroupIDGesture() {
        let nextCount = nextTapCount(
            currentCount: groupIDTapCount,
            startedAt: groupIDTapStartedAt
        )
        groupIDTapCount = nextCount.count
        groupIDTapStartedAt = nextCount.startedAt

        guard groupIDTapCount >= secretTapThreshold else { return }
        groupIDTapCount = 0
        groupIDTapStartedAt = nil
        triggerSentryCrash()
    }

    private func handlePluginVersionGesture() {
        let nextCount = nextTapCount(
            currentCount: pluginVersionTapCount,
            startedAt: pluginVersionTapStartedAt
        )
        pluginVersionTapCount = nextCount.count
        pluginVersionTapStartedAt = nextCount.startedAt

        AppLog.log(
            "🔔 [push] plugin-version tap %ld/%ld",
            pluginVersionTapCount,
            secretTapThreshold
        )

        guard pluginVersionTapCount >= secretTapThreshold else { return }
        pluginVersionTapCount = 0
        pluginVersionTapStartedAt = nil

        // 15 taps on the "plugin vX.Y.Z" segment: export this device's
        // APNS token. Copies to clipboard AND re-fires the PostHog
        // `apns_token_registered` event with `is_manual: true` so the
        // backend can target this device for push tests without
        // round-tripping through the device-token-on-install event.
        guard let token = PushNotificationManager.shared.deviceToken else {
            AppLog.log("🔔 [push] manual export skipped — no device token yet")
            return
        }

        #if os(iOS)
        UIPasteboard.general.string = token
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        #endif

        TelemetryManager.shared.setPersonProperties([
            "apns_device_token": token
        ])
        TelemetryManager.shared.track(
            .apnsTokenRegistered,
            properties: [
                // Same shape as the install-time event so PostHog
                // filtering by `apns_device_token` works whether the
                // event came from install or the 15-tap export.
                "apns_device_token": token,
                "token_len": token.count,
                "is_manual": true,
                "source": "settings_plugin_version_15tap"
            ]
        )

        AppLog.log(
            "🔔 [push] manual export FIRED: copied token (len=%ld prefix=%@) + sent PostHog event",
            token.count,
            String(token.prefix(12))
        )
        Haptics.success()
    }

    private static let diagnosticTapThreshold = 10

    private func handlePrivacyGesture() {
        let nextCount = nextTapCount(
            currentCount: privacyTapCount,
            startedAt: privacyTapStartedAt
        )
        privacyTapCount = nextCount.count
        privacyTapStartedAt = nextCount.startedAt

        guard privacyTapCount >= Self.diagnosticTapThreshold else { return }
        privacyTapCount = 0
        privacyTapStartedAt = nil
        // 20 taps on "Privacy" section header: triggers in-app
        // diagnostic bundle collection. Equivalent to the
        // `chat4000.com/diagnose.sh` flow but contained inside the app
        // so we don't need users to run Terminal commands.
        //
        // We deliberately do NOT show an alert while the report runs.
        // SwiftUI's `.alert(...)` snapshots its message string when
        // first presented and won't update on later @State changes,
        // so the "Collecting…/Encrypting…/Uploading…" animation it
        // attempts is invisible to the user. Wait for the terminal
        // result and pop ONE alert instead.
        Haptics.success()
        DiagnosticReportService.shared.runReport()
    }

    private func nextTapCount(currentCount: Int, startedAt: Date?) -> (count: Int, startedAt: Date) {
        let now = Date()
        guard let startedAt, now.timeIntervalSince(startedAt) <= sentryGestureWindow else {
            return (1, now)
        }
        return (currentCount + 1, startedAt)
    }
}

private enum SentryDevTestError: LocalizedError {
    case simulatedFailure

    var errorDescription: String? {
        "Simulated handled exception from hidden chat4000 settings test"
    }
}

struct AddDevicePairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: MatrixSession

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Add a Device")
                    .font(AppFonts.sheetTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
            }

            pairingBody

            Spacer(minLength: 0)

            // Instructions live at the bottom (v1 layout): the QR + code is the
            // hero up top, the how-to is reference below it.
            VStack(alignment: .leading, spacing: 12) {
                step(1, "Open chat4000 on the new device", "The phone or Mac you want to add.")
                step(2, "Scan the QR, or enter the code", "Either one joins this same account.")
                step(3, "Keep this screen open", "The code is short-lived; leave it up until it connects.")
            }

            Button {
                switch session.devicePairingState.phase {
                case .expired, .cancelled, .failed:
                    session.startDevicePairing()
                default:
                    session.clearDevicePairing()
                    dismiss()
                }
            } label: {
                Text(primaryButtonTitle)
                    .font(AppFonts.button)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.button))
            }
            .buttonStyle(.plain)
            .disabled(session.devicePairingState.phase == .starting)
            .opacity(session.devicePairingState.phase == .starting ? 0.65 : 1)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Edge-to-edge fill so the full-screen cover's background reaches the
        // status bar / home indicator instead of leaving safe-area gaps.
        .background(AppColors.cardBackground.ignoresSafeArea())
        // One click: opening the sheet immediately asks the plugin for a code, so
        // the QR + digits are on screen without a second "Create code" tap.
        .onAppear {
            if session.devicePairingState.phase == .idle {
                session.startDevicePairing()
            }
        }
    }

    /// The pairing code as a Universal Link — `https://pair.chat4000.com/?code=NNNNNN`.
    /// Using the web URL (not the `chat4000://` custom scheme) means the system
    /// Camera app can scan it: it opens the link, which the AASA routes straight
    /// into the app. The in-app scanner still decodes it too (`extractCode` reads
    /// the `code` query param regardless of host/scheme).
    private func pairURI(_ code: String) -> String { "https://pair.chat4000.com/?code=\(code)" }

    @ViewBuilder
    private var pairingBody: some View {
        switch session.devicePairingState.phase {
        case .idle, .starting:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Creating pairing code...")
                    .font(AppFonts.body)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(AppColors.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.input))
        case .codeReady:
            let code = session.devicePairingState.code ?? ""
            VStack(spacing: 16) {
                PairingQRCode(payload: pairURI(code))
                    .frame(width: 190, height: 190)
                    .padding(14)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity)

                Text("Scan this, or enter the code on the new device")
                    .font(AppFonts.label)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)

                PairingCodeBoxes(code: code)
            }
            .frame(maxWidth: .infinity)
        case .completed, .expired, .cancelled, .failed:
            VStack(alignment: .leading, spacing: 10) {
                Label(statusTitle, systemImage: statusIconName)
                    .font(AppFonts.label)
                    .foregroundStyle(statusColor)
                if let message = session.devicePairingState.message {
                    Text(message)
                        .font(AppFonts.body)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(AppColors.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.input))
        }
    }

    private var primaryButtonTitle: String {
        switch session.devicePairingState.phase {
        case .idle, .starting: "Creating..."
        case .codeReady, .completed: "Done"
        case .expired, .cancelled, .failed: "Try Again"
        }
    }

    private var statusTitle: String {
        switch session.devicePairingState.phase {
        case .completed: "Device paired"
        case .expired: "Code expired"
        case .cancelled: "Pairing cancelled"
        case .failed: "Pairing failed"
        default: ""
        }
    }

    private var statusIconName: String {
        switch session.devicePairingState.phase {
        case .completed: "checkmark.circle.fill"
        case .expired: "clock.badge.exclamationmark"
        case .cancelled: "xmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "info.circle"
        }
    }

    private var statusColor: Color {
        switch session.devicePairingState.phase {
        case .completed: AppColors.connected
        case .failed: .red
        default: AppColors.textSecondary
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(AppFonts.sans(12, weight: .bold))
                .foregroundStyle(AppColors.textPrimary)
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.08))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFonts.label)
                    .foregroundStyle(AppColors.textPrimary)
                Text(detail)
                    .font(AppFonts.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Renders a scannable QR code for a pairing payload (a
/// `https://pair.chat4000.com/?code=…` Universal Link). Black modules on a
/// transparent ground — caller puts it on white. Uses
/// CoreImage's built-in generator; nearest-neighbor scaling keeps edges crisp.
struct PairingQRCode: View {
    let payload: String

    private static let context = CIContext()

    var body: some View {
        if let cgImage = Self.makeQR(from: payload) {
            Image(decorative: cgImage, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Pairing QR code")
        } else {
            // Generation should never fail for a short ASCII URI; show a neutral
            // placeholder rather than crashing if it somehow does.
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.08))
                .overlay(
                    Image(systemName: "qrcode")
                        .font(.system(size: 40))
                        .foregroundStyle(.black.opacity(0.3))
                )
        }
    }

    private static func makeQR(from string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Scale up the 1px-per-module output so the rasterized image is sharp.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}

#Preview {
    SettingsSheet(
        matrixSession: MatrixSession(),
        pluginVersion: "0.1.0",
        pluginBundleId: "@chat4000/openclaw-plugin",
        onDisconnect: {}
    )
    .background(AppColors.cardBackground)
}
