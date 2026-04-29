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

    private let tokenDefaultsKey = "chat4000.PushDeviceToken"

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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
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

    func clearBadge() {
        #if os(iOS)
        UNUserNotificationCenter.current().setBadgeCount(0) { error in
            if let error {
                DevLog.log("🔔 [push] clearBadge failed: \(error.localizedDescription)")
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
        DevLog.log(
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
        DevLog.log("🔔 [push] silent push handler finished handled=%@", handled ? "true" : "false")
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
            DevLog.log(
                "🔔 [push] local notification scheduled id=%@ title=%@ body_length=%ld body_prefix=%@",
                request.identifier,
                content.title,
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
        let content = notification.request.content
        DevLog.log(
            "🔔 [push] willPresent id=%@ title=%@ body=%@ badge=%@ trigger=%@",
            notification.request.identifier,
            content.title,
            content.body,
            String(describing: content.badge),
            String(describing: notification.request.trigger)
        )
        completionHandler([.banner, .sound, .list])
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
                if let from = inner.from, from.role == .app {
                    DevLog.log(
                        "🔔 [push] background inner ignored app-side message type=%@ id=%@ device=%@",
                        inner.t.rawValue,
                        inner.id,
                        from.deviceId ?? "nil"
                    )
                    return
                }

                DevLog.log(
                    "🔔 [push] background inner received type=%@ id=%@ from_role=%@",
                    inner.t.rawValue,
                    inner.id,
                    inner.from?.role.rawValue ?? "nil"
                )

                switch inner.body {
                case .text(let body):
                    let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        DevLog.log("🔔 [push] skipping empty text id=%@", inner.id)
                        return
                    }

                    let dedupeKey = "message:\(inner.id)"
                    let queued = await PendingIncomingMessageStore.shared.enqueue(
                        PendingIncomingMessage(
                            dedupeKey: dedupeKey,
                            messageId: inner.id,
                            payload: .text(body.text),
                            receivedAt: .now
                        )
                    )
                    DevLog.log(
                        "🔔 [push] queued text id=%@ chars=%ld queued=%@",
                        inner.id,
                        body.text.count,
                        queued ? "true" : "false"
                    )
                    guard queued else { return }

                    let notified = await PendingIncomingMessageStore.shared.markNotificationSent(
                        for: dedupeKey
                    )
                    guard notified else { return }
                    await PushNotificationManager.shared.presentLocalNotification(body: body.text)

                case .textEnd(let body):
                    if body.reset == true {
                        DevLog.log("🔔 [push] skipping reset text_end id=%@", inner.id)
                        return
                    }

                    let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        DevLog.log("🔔 [push] skipping empty text_end id=%@", inner.id)
                        return
                    }

                    let dedupeKey = "stream-final:\(inner.id)"
                    let queued = await PendingIncomingMessageStore.shared.enqueue(
                        PendingIncomingMessage(
                            dedupeKey: dedupeKey,
                            messageId: inner.id,
                            payload: .text(body.text),
                            receivedAt: .now
                        )
                    )
                    DevLog.log(
                        "🔔 [push] queued text_end id=%@ chars=%ld reset=%@ queued=%@",
                        inner.id,
                        body.text.count,
                        body.reset == true ? "true" : "false",
                        queued ? "true" : "false"
                    )
                    guard queued else { return }

                    let notified = await PendingIncomingMessageStore.shared.markNotificationSent(
                        for: dedupeKey
                    )
                    guard notified else { return }
                    await PushNotificationManager.shared.presentLocalNotification(body: body.text)

                case .image(let body):
                    let dedupeKey = "image:\(inner.id)"
                    let queued = await PendingIncomingMessageStore.shared.enqueue(
                        PendingIncomingMessage(
                            dedupeKey: dedupeKey,
                            messageId: inner.id,
                            payload: .image(dataBase64: body.dataBase64),
                            receivedAt: .now
                        )
                    )
                    DevLog.log(
                        "🔔 [push] queued image id=%@ bytes_b64=%ld queued=%@",
                        inner.id,
                        body.dataBase64.count,
                        queued ? "true" : "false"
                    )

                case .audio(let body):
                    let dedupeKey = "audio:\(inner.id)"
                    let queued = await PendingIncomingMessageStore.shared.enqueue(
                        PendingIncomingMessage(
                            dedupeKey: dedupeKey,
                            messageId: inner.id,
                            payload: .audio(
                                dataBase64: body.dataBase64,
                                mimeType: body.mimeType,
                                durationMs: body.durationMs,
                                waveform: body.waveform
                            ),
                            receivedAt: .now
                        )
                    )
                    DevLog.log(
                        "🔔 [push] queued audio id=%@ duration_ms=%ld queued=%@",
                        inner.id,
                        body.durationMs,
                        queued ? "true" : "false"
                    )

                case .status(let body):
                    DevLog.log("🔔 [push] background status id=%@ status=%@", inner.id, body.status)

                case .textDelta(let body):
                    DevLog.log(
                        "🔔 [push] background text_delta id=%@ chars=%ld",
                        inner.id,
                        body.delta.count
                    )

                default:
                    DevLog.log("🔔 [push] background inner ignored type=%@", inner.t.rawValue)
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
                DevLog.log("🔔 [push] background wake saw relay connected")
                return true
            case .failed:
                DevLog.log("🔔 [push] background wake saw relay failed")
                return false
            default:
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        DevLog.log("🔔 [push] background wake timed out waiting for relay connection")
        return false
    }
}
