import Foundation

enum AnalyticsEvent: String {
    case appOpened = "app_opened"
    case appClosed = "app_closed"
    case pairingCodeSubmitted = "pairing_code_submitted"
    case pairingStarted = "pairing_started"
    case pairingCompleted = "pairing_completed"
    case pairingFailed = "pairing_failed"
    case messageSentText = "message_sent_text"
    case messageSentImage = "message_sent_image"
    case messageSentAudio = "message_sent_audio"
    case voiceRecordingStarted = "voice_recording_started"
    case voiceRecordingFinished = "voice_recording_finished"
    case voiceRecordingFailed = "voice_recording_failed"
    case settingsOpened = "settings_opened"
    case telemetryPreferenceChanged = "telemetry_preference_changed"
    case actionButtonRecordingTriggered = "action_button_recording_triggered"
    case actionButtonComposerTriggered = "action_button_composer_triggered"
    case addDeviceFlowStarted = "add_device_flow_started"
    case legalConsentAccepted = "legal_consent_accepted"

    // Founder-chat / Intercom funnel
    case founderChatOpened = "founder_chat_opened"
    case telegramCommunityOpened = "telegram_community_opened"
    case founderChatPromptShown = "founder_chat_prompt_shown"
    case founderChatPromptAction = "founder_chat_prompt_action"

    /// The user opened the canonical web install page from in-app help, with an
    /// attribution `ref` on the URL so the website can match this app-originated
    /// visit. Gated on diagnostics like every other event.
    case installRefOpened = "install_ref_opened"

    // APNS / push
    case apnsTokenRegistered = "apns_token_registered"
    /// Liveness ping: the backend sends a silent "alive check" push to confirm
    /// the app is still installed; on receipt we emit this (gated on diagnostics
    /// being enabled, like every other event). Its mere presence in PostHog is
    /// the install signal.
    case alive
}

enum AnalyticsBuckets {
    static func lengthBucket(for text: String) -> String {
        let count = text.count
        switch count {
        case 1...20: return "1_20"
        case 21...80: return "21_80"
        case 81...300: return "81_300"
        default: return "301_plus"
        }
    }

    static func durationBucket(for duration: TimeInterval) -> String {
        switch duration {
        case ..<16: return "0_15s"
        case ..<31: return "16_30s"
        case ..<61: return "31_60s"
        default: return "60s_plus"
        }
    }

    static func sessionDurationBucket(for duration: TimeInterval) -> String {
        switch duration {
        case ..<30: return "0_29s"
        case ..<120: return "30_119s"
        case ..<300: return "120_299s"
        case ..<900: return "300_899s"
        default: return "900s_plus"
        }
    }
}
