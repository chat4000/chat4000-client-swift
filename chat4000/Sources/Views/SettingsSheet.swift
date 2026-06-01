import SwiftUI
import Sentry
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SettingsSheet: View {
    private let sentryGestureWindow: TimeInterval = 5.0
    private let secretTapThreshold = 15

    @Environment(\.dismiss) private var dismiss

    let userId: String?
    let pluginVersion: String?
    let pluginBundleId: String?
    var onDisconnect: () -> Void
    var onClearHistory: () -> Void
    /// Optional: ask the paired plugin to update itself (protocol E). Any
    /// control-room member may run it — there's no separate owner role; the
    /// plugin gates on control-room membership. Fire-and-forget.
    var onUpdatePlugin: (() -> Void)? = nil

    @State private var showClearConfirmation = false
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

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Text("Settings")
                        .font(AppFonts.sheetTitle)
                        .foregroundStyle(AppColors.textPrimary)

                    Spacer()

                    Button {
                        dismiss()
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

                    Button {
                        onDisconnect()
                        dismiss()
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

                    Button {
                        showClearConfirmation = true
                    } label: {
                        Text("Clear Chat History")
                            .font(AppFonts.button)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.button))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)

                    if let onUpdatePlugin {
                        Button {
                            onUpdatePlugin()
                            dismiss()
                        } label: {
                            Text("Update Plugin")
                                .font(AppFonts.button)
                                .foregroundStyle(AppColors.textPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(AppColors.inputBackground)
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.button))
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppRadius.button)
                                        .stroke(AppColors.inputBorder, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                    }

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
            "Clear all messages?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                onClearHistory()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
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
        .sheet(isPresented: $showAddDeviceInfo) {
            AddDeviceInfoSheet()
                #if os(macOS)
                .presentationDetents([.height(420)])
                #else
                .presentationDetents([.medium])
                #endif
                .presentationDragIndicator(.visible)
                .presentationBackground(AppColors.cardBackground)
        }
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
                if let userId, !userId.isEmpty {
                    HStack(spacing: 8) {
                        Text("Account")
                            .font(AppFonts.label)
                            .foregroundStyle(AppColors.textSecondary)

                        Text(userId)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppColors.textPrimary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleGroupIDGesture()
                    }
                }

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
                "user_id": userId ?? "none",
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

    private func performNestedSentryThrow() throws {
        try sentryThrowLevelOne()
    }

    private func sentryThrowLevelOne() throws {
        try sentryThrowLevelTwo()
    }

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
            "apns_device_token": token,
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
                "source": "settings_plugin_version_15tap",
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
        if let startedAt, now.timeIntervalSince(startedAt) <= sentryGestureWindow {
            return (currentCount + 1, startedAt)
        } else {
            return (1, now)
        }
    }
}

private enum SentryDevTestError: LocalizedError {
    case simulatedFailure

    var errorDescription: String? {
        "Simulated handled exception from hidden chat4000 settings test"
    }
}

/// "Add Device" explainer. In v2 a device is onboarded by redeeming a 6-digit
/// pairing code that the **plugin** reserves (protocol C); the app cannot mint
/// codes itself (the registrar's `/pair/register` is plugin-service-token-gated,
/// C.1), and device-to-device MSC4108 QR login doesn't fit the appservice-token
/// auth model. So this device can't generate a code — it points the user at the
/// real flow. (Future: a control-room `device.*` command so the app can ask its
/// plugin to mint a code on demand.)
struct AddDeviceInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Add a Device")
                    .font(AppFonts.sheetTitle)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }

            Text("To connect another phone or Mac to this account, pair it the same way you paired this one:")
                .font(AppFonts.body)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                step(1, "Generate a pairing code from your plugin",
                     "Run your OpenClaw / Hermes plugin on your computer and ask it for a new pairing code (it prints a 6-digit code).")
                step(2, "Open chat4000 on the new device",
                     "Install and launch the app on the phone or Mac you want to add.")
                step(3, "Enter the 6-digit code there",
                     "Type or scan the code on the new device's pairing screen. It connects to the same account.")
            }

            Spacer(minLength: 0)

            ChatWithFounderButton(source: "settings_add_device")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppColors.cardBackground)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(AppFonts.mono(12, weight: .bold))
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

#Preview {
    SettingsSheet(
        userId: "@u_demo:chat4000.com",
        pluginVersion: "0.1.0",
        pluginBundleId: "@chat4000/openclaw-plugin",
        onDisconnect: {},
        onClearHistory: {}
    )
    .background(AppColors.cardBackground)
}
