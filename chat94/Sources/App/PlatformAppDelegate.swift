// chat94
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

import Foundation

#if os(iOS)
import UIKit

final class PlatformAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        DevLog.log(
            "🚀 [push] app didFinishLaunching remote_notification_launch=%@",
            launchOptions?[.remoteNotification] == nil ? "false" : "true"
        )
        PushNotificationManager.shared.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        DevLog.log("🔔 [push] didRegisterForRemoteNotifications delegate fired")
        PushNotificationManager.shared.storeDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DevLog.log("⚠️ [push] remote notification registration failed: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        DevLog.log("🔔 [push] app delegate didReceiveRemoteNotification invoked")
        let handled = await PushNotificationManager.shared.handleRemoteNotification(userInfo: userInfo)
        return handled ? .newData : .noData
    }
}
#elseif os(macOS)
import AppKit

final class PlatformAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DevLog.log("🚀 [push] mac app didFinishLaunching")
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        DevLog.log("🔔 [push] mac didRegisterForRemoteNotifications delegate fired")
        PushNotificationManager.shared.storeDeviceToken(deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DevLog.log("⚠️ [push] mac remote notification registration failed: \(error.localizedDescription)")
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        DevLog.log("🔔 [push] mac app delegate didReceiveRemoteNotification invoked")
        Task { @MainActor in
            _ = await PushNotificationManager.shared.handleRemoteNotification(userInfo: userInfo)
        }
    }
}
#endif
