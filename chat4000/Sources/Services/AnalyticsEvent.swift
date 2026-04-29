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
    case addDeviceFlowStarted = "add_device_flow_started"
    case legalConsentAccepted = "legal_consent_accepted"
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
