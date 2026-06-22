import Foundation
import UserNotifications

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()
    static let deviceTokenDidChangeNotification = Notification.Name("chat4000.PushDeviceTokenDidChange")
    static let founderChatPromptRequested = Notification.Name("chat4000.FounderChatPromptRequested")
    private nonisolated static let roomNotificationUserInfoKeys = ["room_id", "roomId", "matrix_room_id"]
    private static let eventNotificationUserInfoKey = "event_id"

    private let tokenDefaultsKey = "chat4000.PushDeviceToken"

    /// Set by the app to drain queued messages on a silent push. MainActor-
    /// isolated so it can reach the live `MatrixSession`.
    var backgroundWakeHandler: (@MainActor () async -> Bool)?

    /// Set by the app to OPEN a room when a message notification is tapped (F).
    /// MainActor-isolated so it can reach the live `MatrixSession`.
    var openRoomHandler: (@MainActor (String) -> Void)?

    var deviceToken: String? {
        UserDefaults.standard.string(forKey: tokenDefaultsKey)
    }

    func configure() {
        #if os(iOS)
        UNUserNotificationCenter.current().delegate = self
        #endif
    }

    func registerForRemoteNotifications() {
        #if os(macOS)
        AppLog.log("🔔 [push] registerForRemoteNotifications skipped on macOS")
        return
        #else
        configure()
        AppLog.log(
            "🔔 [push] starting APNS registration (existing_token=%@)",
            deviceToken == nil ? "false" : "true"
        )
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppLog.log("⚠️ [push] notification authorization failed: \(error.localizedDescription)")
            } else {
                AppLog.log("🔔 [push] notification authorization granted: \(granted)")
            }

            Task { @MainActor in
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                AppLog.log(
                    "🔔 [push] notification settings auth=%ld alert=%ld sound=%ld badge=%ld",
                    settings.authorizationStatus.rawValue,
                    settings.alertSetting.rawValue,
                    settings.soundSetting.rawValue,
                    settings.badgeSetting.rawValue
                )
                #if os(iOS)
                AppLog.log("🔔 [push] calling UIApplication.registerForRemoteNotifications()")
                UIApplication.shared.registerForRemoteNotifications()
                #elseif os(macOS)
                NSApplication.shared.registerForRemoteNotifications()
                #endif
            }
        }
        #endif
    }

    func clearBadge() {
        #if os(iOS)
        UNUserNotificationCenter.current().setBadgeCount(0) { error in
            if let error {
                AppLog.log("🔔 [push] clearBadge failed: \(error.localizedDescription)")
            }
        }
        #endif
    }

    func clearSessionNotifications(roomId: String) {
        #if os(macOS)
        _ = roomId
        return
        #else
        Task {
            let center = UNUserNotificationCenter.current()
            let delivered = await center.deliveredNotifications()
            let pending = await center.pendingNotificationRequests()
            let deliveredIds = delivered
                .filter { Self.notificationMatches(roomId: roomId, request: $0.request) }
                .map(\.request.identifier)
            let pendingIds = pending
                .filter { Self.notificationMatches(roomId: roomId, request: $0) }
                .map(\.identifier)

            if !deliveredIds.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: deliveredIds)
            }
            if !pendingIds.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: pendingIds)
            }

            guard !deliveredIds.isEmpty || !pendingIds.isEmpty else { return }
            AppLog.log(
                "🔔 [push] cleared session notifications room=%@ delivered=%ld pending=%ld",
                roomId,
                deliveredIds.count,
                pendingIds.count
            )

            let remaining = await center.deliveredNotifications()
            if remaining.isEmpty {
                clearBadge()
            }
        }
        #endif
    }

    func storeDeviceToken(_ tokenData: Data) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        let previous = UserDefaults.standard.string(forKey: tokenDefaultsKey)
        UserDefaults.standard.set(token, forKey: tokenDefaultsKey)
        AppLog.log(
            "🔔 [push] stored remote notification token len=%ld prefix=%@",
            token.count,
            String(token.prefix(12))
        )

        // Push the APNS token to PostHog as a person property so the
        // backend can send targeted notifications (founder-chat prompts,
        // etc.) by querying PostHog for users with this property set.
        // Fire on first registration AND on any token rotation.
        if previous != token {
            TelemetryManager.shared.setPersonProperties([
                "apns_device_token": token,
                "apns_env": Self.apnsEnvironment,
                "platform": Self.platformName
            ])
            TelemetryManager.shared.track(
                .apnsTokenRegistered,
                properties: [
                    // Full token also lives on the event so it's visible
                    // in the PostHog Events panel without round-tripping
                    // through the person-properties view.
                    "apns_device_token": token,
                    "token_len": token.count,
                    "is_first": previous == nil,
                    "apns_env": Self.apnsEnvironment
                ]
            )
        }

        NotificationCenter.default.post(name: Self.deviceTokenDidChangeNotification, object: nil)
    }

    private static var apnsEnvironment: String {
        Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String ?? "unknown"
    }

    /// `userInfo["type"]` value the backend sets on the silent liveness-ping push
    /// (see `handleRemoteNotification`). A bare install check — emits `alive`, no sync.
    static let aliveCheckPushType = "alive_check"

    private static var platformName: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #else
        return "unknown"
        #endif
    }

    func handleRemoteNotification(userInfo: [AnyHashable: Any]) async -> Bool {
        let silent = isSilentPush(userInfo)
        let aps = userInfo["aps"] as? [String: Any]
        let alertDescription: String
        if let alert = aps?["alert"] as? [String: Any] {
            let title = alert["title"] as? String ?? ""
            let body = alert["body"] as? String ?? ""
            alertDescription = "dict(title=\(title),body=\(body))"
        } else if let alert = aps?["alert"] as? String {
            alertDescription = "string(\(alert))"
        } else {
            alertDescription = "none"
        }
        AppLog.log(
            "🔔 [push] remote notification received silent=%@ keys=%@ aps_keys=%@ badge=%@ content_available=%@ mutable_content=%@ alert=%@",
            silent ? "true" : "false",
            userInfo.keys.map { String(describing: $0) }.sorted().joined(separator: ","),
            aps?.keys.sorted().joined(separator: ",") ?? "none",
            String(describing: aps?["badge"]),
            String(describing: aps?["content-available"]),
            String(describing: aps?["mutable-content"]),
            alertDescription
        )
        // Liveness ping: a silent "alive check" push the backend sends purely to
        // confirm the app is still installed. We don't sync/wake for it — we just
        // emit the `alive` event (which `track` drops automatically if diagnostics
        // collection is turned off), and its presence in PostHog is the signal.
        if (userInfo["type"] as? String) == Self.aliveCheckPushType {
            AppLog.log("🔔 [push] alive-check ping → emitting alive event")
            TelemetryManager.shared.track(.alive, properties: ["platform": Self.platformName])
            return true
        }

        guard silent else { return false }
        let handled = await backgroundWakeHandler?() ?? false
        AppLog.log("🔔 [push] silent push handler finished handled=%@", handled ? "true" : "false")
        return handled
    }

    func presentLocalNotification(body: String, roomId: String? = nil, eventId: String? = nil) async {
        #if os(macOS)
        _ = body
        _ = roomId
        _ = eventId
        return
        #else
        let content = UNMutableNotificationContent()
        content.title = "chat4000"
        content.body = body
        content.sound = .default
        if let roomId {
            content.threadIdentifier = roomId
            content.userInfo[Self.roomNotificationUserInfoKeys[0]] = roomId
        }
        if let eventId {
            content.userInfo[Self.eventNotificationUserInfoKey] = eventId
        }

        let request = UNNotificationRequest(
            identifier: eventId ?? UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            TelemetryManager.shared.track(.notificationDisplayed, properties: ["type": "message"])  // CL16
            AppLog.log(
                "🔔 [push] local notification scheduled id=%@ title=%@ body_length=%ld body_prefix=%@",
                request.identifier,
                content.title,
                body.count,
                String(body.prefix(32))
            )
        } catch {
            ErrorReporter.capture(error, context: "PushNotificationService.enqueueLocalNotification")
            AppLog.log("⚠️ [push] failed to enqueue local notification: \(error.localizedDescription)")
        }
        #endif
    }

    private func isSilentPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let aps = userInfo["aps"] as? [String: Any] else { return false }
        return (aps["content-available"] as? Int) == 1
    }

    // MARK: - Analytics helpers (CL16 / CL17 / CL24)

    private nonisolated static let pendingOpenViaPushKey = "chat4000.analytics.pendingOpenViaPush"
    private nonisolated static let pendingOpenPushIdKey = "chat4000.analytics.pendingOpenPushId"

    /// Lenient bool from a push payload field (JSON `true`, NSNumber 1, or the
    /// strings "true"/"1"/"yes"). Used for `disable_whatsapp` / `disable_telegram`.
    nonisolated static func boolFlag(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
        return false
    }

    /// CL16/CL17 notification `type`: a founder-chat prompt vs an ordinary message.
    nonisolated static func notificationType(_ userInfo: [AnyHashable: Any]) -> String {
        (userInfo["type"] as? String) == "founder_chat_prompt" ? "founder_prompt" : "message"
    }

    /// CL24: record that the app is being entered via a notification tap; the next
    /// `app_opened` consumes this to attribute `source=push`. UserDefaults so the
    /// nonisolated delegate callback can write it synchronously off the main actor.
    nonisolated static func markOpenedViaPush(pushId: String?) {
        UserDefaults.standard.set(true, forKey: pendingOpenViaPushKey)
        if let pushId {
            UserDefaults.standard.set(pushId, forKey: pendingOpenPushIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: pendingOpenPushIdKey)
        }
    }

    /// CL24: read + clear the open attribution. Returns `("push", pushId?)` once
    /// after a tap, else `("direct", nil)`.
    nonisolated static func consumeOpenSource() -> (source: String, pushId: String?) {
        let viaPush = UserDefaults.standard.bool(forKey: pendingOpenViaPushKey)
        let pushId = UserDefaults.standard.string(forKey: pendingOpenPushIdKey)
        UserDefaults.standard.removeObject(forKey: pendingOpenViaPushKey)
        UserDefaults.standard.removeObject(forKey: pendingOpenPushIdKey)
        return viaPush ? ("push", pushId) : ("direct", nil)
    }

    private static func notificationMatches(roomId: String, request: UNNotificationRequest) -> Bool {
        for key in roomNotificationUserInfoKeys where (request.content.userInfo[key] as? String) == roomId {
            return true
        }
        return request.content.threadIdentifier == roomId
    }
}

extension PushNotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let content = notification.request.content
        AppLog.log(
            "🔔 [push] willPresent id=%@ title=%@ body=%@ badge=%@ trigger=%@",
            notification.request.identifier,
            content.title,
            content.body,
            String(describing: content.badge),
            String(describing: notification.request.trigger)
        )
        // If this is a founder-chat prompt and the app is foregrounded,
        // surface the in-app modal AND show the banner so the user can
        // pick either entry point.
        let userInfo = notification.request.content.userInfo
        if let type = userInfo["type"] as? String, type == "founder_chat_prompt" {
            let source = (userInfo["source"] as? String) ?? "push"
            let modalTitle = userInfo["modal_title"] as? String
            let modalBody = userInfo["modal_body"] as? String
            let pushId = userInfo["push_id"] as? String
            let contactMessage = userInfo["contact_message"] as? String
            let disableWhatsApp = Self.boolFlag(userInfo["disable_whatsapp"])
            let disableTelegram = Self.boolFlag(userInfo["disable_telegram"])
            Task { @MainActor in
                // CL16 notification_displayed (founder prompt, foreground present).
                var props: [String: Any] = ["type": "founder_prompt"]
                if let pushId { props["push_id"] = pushId }
                TelemetryManager.shared.track(.notificationDisplayed, properties: props)
                Self.shared.handleFounderChatPromptPush(
                    source: source,
                    modalTitle: modalTitle,
                    modalBody: modalBody,
                    contactMessage: contactMessage,
                    disableWhatsApp: disableWhatsApp,
                    disableTelegram: disableTelegram
                )
            }
        }
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        AppLog.log(
            "🔔 [push] didReceive action=%@ id=%@ keys=%@",
            response.actionIdentifier,
            response.notification.request.identifier,
            userInfo.keys.map { String(describing: $0) }.sorted().joined(separator: ",")
        )
        // CL17 notification_tapped + CL24 push attribution for the next app_opened.
        let tapType = Self.notificationType(userInfo)
        let tapPushId = userInfo["push_id"] as? String
        Self.markOpenedViaPush(pushId: tapPushId)
        Task { @MainActor in
            var props: [String: Any] = ["type": tapType]
            if let tapPushId { props["push_id"] = tapPushId }
            TelemetryManager.shared.track(.notificationTapped, properties: props)
        }
        // Message-notification tap → OPEN that room (F). Extract the room id the
        // gateway attached to the payload (the same keys the NSE reads). The room may
        // not be loaded yet on a cold launch / brand-new session — openRoomFromPush
        // defers to the next sync via autoOpen in that case.
        if let roomId = Self.roomNotificationUserInfoKeys
            .lazy
            .compactMap({ userInfo[$0] as? String })
            .first(where: { !$0.isEmpty }) {
            AppLog.log("🔔 [push] tap → open room %@", roomId)
            Task { @MainActor in Self.shared.openRoomHandler?(roomId) }
        }
        if let type = userInfo["type"] as? String, type == "founder_chat_prompt" {
            let source = (userInfo["source"] as? String) ?? "push_tap"
            let modalTitle = userInfo["modal_title"] as? String
            let modalBody = userInfo["modal_body"] as? String
            let contactMessage = userInfo["contact_message"] as? String
            let disableWhatsApp = Self.boolFlag(userInfo["disable_whatsapp"])
            let disableTelegram = Self.boolFlag(userInfo["disable_telegram"])
            Task { @MainActor in
                Self.shared.handleFounderChatPromptPush(
                    source: source,
                    modalTitle: modalTitle,
                    modalBody: modalBody,
                    contactMessage: contactMessage,
                    disableWhatsApp: disableWhatsApp,
                    disableTelegram: disableTelegram
                )
            }
        }
        completionHandler()
    }
}

extension PushNotificationManager {
    /// Posts the in-app notification that triggers `FounderChatPromptModal`.
    /// Snooze-aware: if the user picked "Remind me later" within the last
    /// 24 hours, this is a no-op.
    func handleFounderChatPromptPush(
        source: String,
        modalTitle: String? = nil,
        modalBody: String? = nil,
        contactMessage: String? = nil,
        disableWhatsApp: Bool = false,
        disableTelegram: Bool = false
    ) {
        guard !FounderChatPromptStore.shared.isSnoozed else {
            AppLog.log("🔔 [push] founder_chat_prompt suppressed (snoozed) source=%@", source)
            TelemetryManager.shared.track(
                .founderChatPromptShown,
                properties: ["source": source, "suppressed": "snoozed"]
            )
            return
        }
        AppLog.log(
            "🔔 [push] founder_chat_prompt firing source=%@ title=%@ body=%@ disable_wa=%@ disable_tg=%@",
            source,
            modalTitle ?? "<default>",
            modalBody ?? "<default>",
            String(disableWhatsApp),
            String(disableTelegram)
        )
        FounderChatPromptStore.shared.storePendingPrompt(
            FounderChatPromptRequest(
                source: source,
                modalTitle: modalTitle,
                modalBody: modalBody,
                contactMessage: contactMessage,
                disableWhatsApp: disableWhatsApp,
                disableTelegram: disableTelegram
            )
        )
        var info: [AnyHashable: Any] = ["source": source]
        if let modalTitle { info["modal_title"] = modalTitle }
        if let modalBody { info["modal_body"] = modalBody }
        NotificationCenter.default.post(
            name: Self.founderChatPromptRequested,
            object: nil,
            userInfo: info
        )
    }
}
