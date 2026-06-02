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

    private let tokenDefaultsKey = "chat4000.PushDeviceToken"

    /// Set by the app to drain queued messages on a silent push. MainActor-
    /// isolated so it can reach the live `MatrixSession`.
    var backgroundWakeHandler: (@MainActor () async -> Bool)?

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
        guard silent else { return false }
        let handled = await backgroundWakeHandler?() ?? false
        AppLog.log("🔔 [push] silent push handler finished handled=%@", handled ? "true" : "false")
        return handled
    }

    func presentLocalNotification(body: String) async {
        #if os(macOS)
        _ = body
        return
        #else
        let content = UNMutableNotificationContent()
        content.title = "chat4000"
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
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
            Task { @MainActor in
                Self.shared.handleFounderChatPromptPush(
                    source: source,
                    modalTitle: modalTitle,
                    modalBody: modalBody
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
        if let type = userInfo["type"] as? String, type == "founder_chat_prompt" {
            let source = (userInfo["source"] as? String) ?? "push_tap"
            let modalTitle = userInfo["modal_title"] as? String
            let modalBody = userInfo["modal_body"] as? String
            Task { @MainActor in
                Self.shared.handleFounderChatPromptPush(
                    source: source,
                    modalTitle: modalTitle,
                    modalBody: modalBody
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
        modalBody: String? = nil
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
            "🔔 [push] founder_chat_prompt firing source=%@ title=%@ body=%@",
            source,
            modalTitle ?? "<default>",
            modalBody ?? "<default>"
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
