import Foundation

/// The founder-chat ("we'd love to interview you") prompt payload — from an APNS
/// push or the QA trigger. Lives in Shared so BOTH the app and the Notification
/// Service Extension can build and store it.
struct FounderChatPromptRequest: Codable, Equatable {
    let source: String
    let modalTitle: String?
    let modalBody: String?
    /// Prefill text for the WhatsApp / Intercom outreach (from the push, optional).
    var contactMessage: String?
    /// Push overrides to force-skip a channel so the next one can be tested without
    /// uninstalling the app (e.g. skip WhatsApp to verify Telegram).
    var disableWhatsApp: Bool?
    var disableTelegram: Bool?
}

/// Cross-process pending-prompt store, backed by the shared App-Group defaults so
/// a founder push stored by the NSE on DELIVERY is picked up by the app on the
/// next foreground — even if the user DISMISSED the notification without tapping
/// it. Snooze-aware. Not `@MainActor`: the NSE runs off-main and `UserDefaults`
/// is thread-safe. Falls back to `.standard` when the app group is unavailable
/// (then app↔NSE can't share, but the in-app tap/foreground paths still work).
enum FounderPromptPending {
    private static let pendingKey = "chat4000.FounderChatPrompt.pendingPrompt"
    private static let snoozeUntilKey = "chat4000.FounderChatPrompt.snoozeUntil"
    private static let snoozeWindow: TimeInterval = 60 * 60 * 24   // 24h

    private static var defaults: UserDefaults {
        AppGroup.sharedDefaults ?? .standard
    }

    static var isSnoozed: Bool {
        guard let until = defaults.object(forKey: snoozeUntilKey) as? Date else { return false }
        return until > Date()
    }

    static func snoozeForOneDay() {
        defaults.set(Date().addingTimeInterval(snoozeWindow), forKey: snoozeUntilKey)
    }

    static func clearSnooze() {
        defaults.removeObject(forKey: snoozeUntilKey)
    }

    /// Store a prompt to surface on the next app foreground. No-op while snoozed.
    static func store(_ request: FounderChatPromptRequest) {
        guard !isSnoozed else { return }
        guard let data = try? JSONEncoder().encode(request) else {
            AppLog.log("⚠️ [founder] failed to encode pending prompt")
            return
        }
        defaults.set(data, forKey: pendingKey)
        AppLog.log("🔔 [founder] stored pending prompt source=%@", request.source)
    }

    /// Read + clear the pending prompt (returns nil when none / decode fails).
    static func consume() -> FounderChatPromptRequest? {
        guard let data = defaults.data(forKey: pendingKey) else { return nil }
        defaults.removeObject(forKey: pendingKey)
        guard let request = try? JSONDecoder().decode(FounderChatPromptRequest.self, from: data) else {
            AppLog.log("⚠️ [founder] failed to decode pending prompt")
            return nil
        }
        AppLog.log("🔔 [founder] consumed pending prompt source=%@", request.source)
        return request
    }
}
