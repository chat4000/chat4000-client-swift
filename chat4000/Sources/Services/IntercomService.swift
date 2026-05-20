import Foundation

#if os(iOS)
import Intercom
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Thin wrapper around Intercom for in-app live chat with the founders.
///
/// **Scaffolded with placeholders.** Fill in the real `appId` and `apiKey`
/// once the Intercom workspace is provisioned. The wrapper is otherwise
/// fully wired — `openMessenger()` will work as soon as creds land.
///
/// **macOS path:** uses Intercom's web messenger via `WKWebView`
/// (`IntercomMacWebView`). Intercom does not ship a native macOS SDK
/// (confirmed by Intercom Engineering July 2024) and recommends the
/// web-embed approach for desktop apps. Conversations land in the same
/// Intercom workspace inbox as iOS once identified-user (JWT) mode is
/// enabled in `IntercomConfig`.
@MainActor
enum IntercomService {
    /// Intercom workspace App ID. Find it at Intercom → Settings →
    /// Installation → iOS (it's the workspace slug shown in the URL).
    /// Keep in sync with `IntercomConfig.appId` (used by the Mac webview).
    private static let appId = "mdj5dae1"

    /// Intercom Mobile SDK API key. Found at the same Installation page;
    /// starts with `ios_sdk-...`.
    private static let apiKey = "ios_sdk-af4115828b5d7aa18cfbd510cb7be878c621fe8a"

    static let macWebMessengerRequested = Notification.Name("chat4000.IntercomMacWebMessengerRequested")

    private static var didStart = false

    /// Call once at app launch, after PostHog is configured. No-op if
    /// placeholder creds are still in place.
    static func startIfConfigured() {
        #if os(iOS)
        guard !didStart else { return }
        guard appId != "PLACEHOLDER_APP_ID", apiKey != "PLACEHOLDER_API_KEY" else {
            AppLog.log("💬 [intercom] not configured (placeholder creds), skipping start")
            return
        }
        Intercom.setApiKey(apiKey, forAppId: appId)
        // Register an anonymous user so message history persists across
        // launches. Once we have a stable per-device user id we can switch
        // to `loginUser` with that id.
        Intercom.loginUnidentifiedUser()
        didStart = true
        AppLog.log("💬 [intercom] started for app_id=%@", String(appId.prefix(8)))
        #else
        AppLog.log("💬 [intercom] startIfConfigured skipped on macOS (web messenger loaded on-demand)")
        #endif
    }

    /// Open the Intercom messenger (native iOS SDK / Mac WKWebView).
    /// Tracks `founder_chat_opened` with the requested source for funnel
    /// analysis.
    static func openMessenger(source: String) {
        TelemetryManager.shared.track(
            .founderChatOpened,
            properties: ["source": source]
        )

        #if os(iOS)
        guard didStart else {
            AppLog.log("💬 [intercom] openMessenger called before start (placeholder creds)")
            return
        }
        Intercom.present()
        #elseif os(macOS)
        AppLog.log("💬 [intercom] opening mac web messenger window source=%@", source)
        IntercomMacWindowController.shared.present(source: source)
        // Also fire the notification so any future observers can hook in.
        NotificationCenter.default.post(
            name: Self.macWebMessengerRequested,
            object: nil,
            userInfo: ["source": source]
        )
        #endif
    }
}
