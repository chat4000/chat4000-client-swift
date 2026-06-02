#if os(iOS)
import AppIntents

/// App Intent: open chat4000 and start recording a voice note.
/// One of two discrete shortcuts the user can pick when configuring the
/// iPhone Action Button (Settings → Action Button → Shortcut).
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

/// App Intent: open chat4000 with the message input focused, ready to type.
/// The text-input alternative to `StartVoiceRecordingIntent` — pick this
/// one in iOS Settings → Action Button → Shortcut if you prefer typing
/// over voice notes when the Action Button fires.
struct OpenComposerIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Open chat4000 to Type"
    static let description = IntentDescription("Open chat4000 and focus the message input so you can start typing right away.")
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        if #available(iOS 26.0, *) {
            LaunchActionStore.set(.openComposer)
            try await continueInForeground(nil, alwaysConfirm: false)
        } else {
            try await requestToContinueInForeground {
                LaunchActionStore.set(.openComposer)
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
                "Open \(.applicationName) and record"
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: OpenComposerIntent(),
            phrases: [
                "Type in \(.applicationName)",
                "Compose in \(.applicationName)",
                "Open \(.applicationName) to type"
            ],
            shortTitle: "Open to Type",
            systemImageName: "keyboard"
        )
    }
}
#endif
