#if os(iOS)
import AppIntents

struct StartVoiceRecordingIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Start Voice Recording"
    static let description = IntentDescription("Open chat4000 and start recording a voice message.")
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        if #available(iOS 26.0, *) {
            LaunchActionStore.set(.startVoiceRecording)
            try await continueInForeground(nil, alwaysConfirm: false)
        } else {
            try await requestToContinueInForeground {
                LaunchActionStore.set(.startVoiceRecording)
            }
        }
        return .result()
    }
}

struct chat4000Shortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .blue }

    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVoiceRecordingIntent(),
            phrases: [
                "Start recording in \(.applicationName)",
                "Record with \(.applicationName)",
                "Open \(.applicationName) and record",
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill"
        )
    }
}
#endif
