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
    static let deviceTokenDidChangeNotification = Notification.Name("chat94.PushDeviceTokenDidChange")

    private let tokenDefaultsKey = "chat94.PushDeviceToken"

    var backgroundWakeHandler: (@Sendable () async -> Bool)?

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
        DevLog.log("🔔 [push] registerForRemoteNotifications skipped on macOS")
        return
        #else
        configure()
        DevLog.log(
            "🔔 [push] starting APNS registration (existing_token=%@)",
            deviceToken == nil ? "false" : "true"
        )
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error {
                DevLog.log("⚠️ [push] notification authorization failed: \(error.localizedDescription)")
            } else {
                DevLog.log("🔔 [push] notification authorization granted: \(granted)")
            }

            Task { @MainActor in
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                DevLog.log(
                    "🔔 [push] notification settings auth=%ld alert=%ld sound=%ld badge=%ld",
                    settings.authorizationStatus.rawValue,
                    settings.alertSetting.rawValue,
                    settings.soundSetting.rawValue,
                    settings.badgeSetting.rawValue
                )
                #if os(iOS)
                DevLog.log("🔔 [push] calling UIApplication.registerForRemoteNotifications()")
                UIApplication.shared.registerForRemoteNotifications()
                #elseif os(macOS)
                NSApplication.shared.registerForRemoteNotifications()
                #endif
            }
        }
        #endif
    }

    func storeDeviceToken(_ tokenData: Data) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: tokenDefaultsKey)
        DevLog.log(
            "🔔 [push] stored remote notification token len=%ld prefix=%@",
            token.count,
            String(token.prefix(12))
        )
        NotificationCenter.default.post(name: Self.deviceTokenDidChangeNotification, object: nil)
    }

    func handleRemoteNotification(userInfo: [AnyHashable: Any]) async -> Bool {
        let silent = isSilentPush(userInfo)
        DevLog.log(
            "🔔 [push] remote notification received silent=%@ keys=%@",
            silent ? "true" : "false",
            userInfo.keys.map { String(describing: $0) }.sorted().joined(separator: ",")
        )
        guard silent else { return false }
        let handled = await backgroundWakeHandler?() ?? false
        DevLog.log("🔔 [push] silent push handler finished handled=%@", handled ? "true" : "false")
        return handled
    }

    func presentLocalNotification(body: String) async {
        #if os(macOS)
        _ = body
        return
        #else
        let content = UNMutableNotificationContent()
        content.title = "chat94"
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            DevLog.log(
                "🔔 [push] local notification scheduled body_length=%ld body_prefix=%@",
                body.count,
                String(body.prefix(32))
            )
        } catch {
            DevLog.log("⚠️ [push] failed to enqueue local notification: \(error.localizedDescription)")
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
        completionHandler([.banner, .sound, .badge, .list])
    }
}

@MainActor
final class BackgroundRelayWakeService {
    static let shared = BackgroundRelayWakeService()

    private var isRunning = false

    func handleSilentPush() async -> Bool {
        guard !isRunning else {
            DevLog.log("🔔 [push] background wake already running, skipping duplicate wake")
            return true
        }
        guard let config = KeychainService.load() else {
            DevLog.log("🔔 [push] silent push received but no saved pair config exists")
            return false
        }

        DevLog.log("🔔 [push] background wake starting relay reconnect")
        isRunning = true
        defer {
            isRunning = false
            DevLog.log("🔔 [push] background wake finished")
        }

        let relay = RelayClient()
        relay.onInnerMessage = { inner in
            Task { @MainActor in
                switch inner.body {
                case .text(let body):
                    await PushNotificationManager.shared.presentLocalNotification(body: body.text)
                case .textEnd(let body):
                    await PushNotificationManager.shared.presentLocalNotification(body: body.text)
                default:
                    break
                }
            }
        }

        relay.connect(config: config)

        let connected = await waitForRelayConnection(relay)
        DevLog.log("🔔 [push] background wake relay connected=%@", connected ? "true" : "false")
        if connected {
            try? await Task.sleep(for: .seconds(8))
        }

        relay.disconnect()
        return connected
    }

    private func waitForRelayConnection(_ relay: RelayClient) async -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            switch relay.state {
            case .connected:
                return true
            case .failed:
                return false
            default:
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return false
    }
}
