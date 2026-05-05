import Foundation

/// Holds a `ProcessInfo.beginActivity(...)` token while the relay WebSocket is
/// active, preventing macOS App Nap from suspending the receive loop.
///
/// Without this, an unfocused chat4000 window gets quietly suspended by
/// macOS, the relay's idle-ping fails, the connection RSTs, and any
/// kernel-buffered frames that the receive loop hadn't drained yet are lost.
/// This is the primary cause of the silent-message-loss bug observed in
/// production builds. iOS does not have App Nap, so this is a no-op there.
@MainActor
final class AppNapBlocker {
    static let shared = AppNapBlocker()

    private var token: NSObjectProtocol?

    private init() {}

    /// Block App Nap. Idempotent: subsequent begin() calls are no-ops while
    /// a token is held.
    func begin(reason: String = "chat4000-relay-active") {
        #if os(macOS)
        guard token == nil else { return }
        let options: ProcessInfo.ActivityOptions = [
            .userInitiated,
            .idleSystemSleepDisabled
        ]
        token = ProcessInfo.processInfo.beginActivity(
            options: options,
            reason: reason
        )
        AppLog.log("🛌 App Nap blocked — reason=\(reason)")
        #endif
    }

    /// Release the activity token. Called on full disconnect or extended idle.
    func end() {
        #if os(macOS)
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
        AppLog.log("🛌 App Nap released")
        #endif
    }
}
