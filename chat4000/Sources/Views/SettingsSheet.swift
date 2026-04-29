import SwiftUI
import Sentry

struct SettingsSheet: View {
    private let sentryGestureWindow: TimeInterval = 1.5

    @Environment(\.dismiss) private var dismiss

    let config: GroupConfig?
    let pluginVersion: String?
    let pluginBundleId: String?
    var onAddDevice: () -> Void
    var onDisconnect: () -> Void
    var onClearHistory: () -> Void

    @State private var showClearConfirmation = false
    @State private var sentryResultMessage: String?
    @State private var showSentryResult = false
    @State private var addDeviceTapCount = 0
    @State private var addDeviceTapStartedAt: Date?
    @State private var groupIDTapCount = 0
    @State private var groupIDTapStartedAt: Date?
    @State private var isCollectionEnabled = TelemetryPreferences.isCollectionEnabled

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

                    TalkToTeamCallout(caption: "Need help, or just want to say hi?")
                        .padding(.horizontal, 16)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                Text(versionFooter)
                    .font(AppFonts.caption)
                    .foregroundStyle(AppColors.textTimestamp)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleAddAnotherDeviceGesture()
                    }
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
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Devices")
                .font(AppFonts.sectionTitle)
                .foregroundStyle(AppColors.textSecondary)

            VStack(alignment: .leading, spacing: 16) {
                if let groupId = config?.groupId {
                    HStack(spacing: 8) {
                        Text("Group ID")
                            .font(AppFonts.label)
                            .foregroundStyle(AppColors.textSecondary)

                        Text(String(groupId.prefix(8)))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppColors.textPrimary)
                            .textSelection(.enabled)

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleGroupIDGesture()
                    }
                }

                Button {
                    dismiss()
                    onAddDevice()
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
                "group_id": config?.groupId ?? "none",
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

        guard addDeviceTapCount >= 5 else { return }
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

        guard groupIDTapCount >= 5 else { return }
        groupIDTapCount = 0
        groupIDTapStartedAt = nil
        triggerSentryCrash()
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

#Preview {
    SettingsSheet(
        config: GroupConfig(groupKey: Data(repeating: 7, count: 32)),
        pluginVersion: "0.1.0",
        pluginBundleId: "@chat4000/openclaw-plugin",
        onAddDevice: {},
        onDisconnect: {},
        onClearHistory: {}
    )
    .background(AppColors.cardBackground)
}
