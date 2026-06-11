import Foundation

enum AnalyticsEvent: String {
    case appOpened = "app_opened"
    case appClosed = "app_closed"
    case pairingCodeSubmitted = "pairing_code_submitted"
    case pairingLinkOpened = "pairing_link_opened"
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

    // ── Analytics plan v5 — CL events ──────────────────────────────────────
    // IDN3 first-launch classifier (exactly one per (re)install).
    case appInstalled = "app_installed"          // CL3
    case appReinstalled = "app_reinstalled"      // CL4
    case deviceSwapped = "device_swapped"        // CL5
    // IDN4 account link.
    case accountLinked = "account_linked"        // CL6
    // Session lifecycle (all carry `session_count`).
    case sessionCreated = "session_created"      // CL7  {source, session_count}
    case sessionSwitched = "session_switched"    // CL8
    case sessionRenamed = "session_renamed"      // CL9
    case sessionDeleted = "session_deleted"      // CL10
    case sessionPinned = "session_pinned"        // CL11
    case sessionUnpinned = "session_unpinned"    // CL11
    case sessionMuted = "session_muted"          // CL12
    case sessionUnmuted = "session_unmuted"      // CL12
    case clearHistoryConfirmed = "clear_history_confirmed" // CL13
    case disconnectTapped = "disconnect_tapped"  // CL14  churn signal
    case fullSyncTriggered = "full_sync_triggered" // CL15
    case notificationDisplayed = "notification_displayed"  // CL16
    case notificationTapped = "notification_tapped"        // CL17
    case messageReceived = "message_received"    // CL18  {kind, turn_duration_bucket?}
    case helpMenuOpened = "help_menu_opened"     // CL19
    case helpRouteSelected = "help_route_selected" // CL20
    case addDeviceFlowCompleted = "add_device_flow_completed" // CL21
    case addDeviceFlowFailed = "add_device_flow_failed"       // CL21
    case diagnosticStarted = "diagnostic_started"     // CL23
    case diagnosticCompleted = "diagnostic_completed" // CL23

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

    /// CL18 turn duration (final-answer ts − busy-clock start). Plan-pinned buckets.
    static func turnDurationBucket(for duration: TimeInterval) -> String {
        switch duration {
        case ..<6: return "0_5s"
        case ..<16: return "6_15s"
        case ..<61: return "16_60s"
        case ..<301: return "61_300s"
        default: return "300s_plus"
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
