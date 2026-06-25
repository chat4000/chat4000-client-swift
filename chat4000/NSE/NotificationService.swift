// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

import UserNotifications

// ─────────────────────────────────────────────────────────────────────────────
// NotificationService — the iOS Notification Service Extension (protocol F.2,
// F.2.1–F.2.5). It wakes on the gateway's `mutable-content: 1` alert, reads the
// `room_id` / `event_id` / `account_id` references off the payload, fetches the
// referenced ciphertext event through the gateway (no lock), decrypts it locally
// with the device's already-present Megolm key (under the cross-process lock),
// and REPLACES the banner body with the real text. On ANY miss it leaves the
// unmodified generic placeholder (`chat4000` / `New message`) — a fallback is
// never an error to the user (F.2.2).
//
// DEDUPE (F.2.2): we stamp `event_id` into the delivered notification's userInfo
// so duplicate deliveries reconcile; the system replacement keys on the request
// identifier the OS carries through this extension.
//
// CONCURRENCY: the system invokes a notification-service extension's two callbacks
// SERIALLY on one queue — `didReceive` then, at most, `serviceExtensionTimeWill
// expire`, never concurrently. The `UNNotificationContent` / content-handler
// types aren't Sendable, so they're held in `nonisolated(unsafe)` storage whose
// safety rests on that single-threaded contract. The decrypt itself runs on the
// @MainActor (PushDecryptor) and returns a Sendable `Content`; only the
// (Sendable) result crosses back to apply onto the content.
// ─────────────────────────────────────────────────────────────────────────────

// `@unchecked Sendable`: the state below is touched only from the system's serial
// extension-callback queue and the single follow-on Task (which awaits before it
// touches anything), never concurrently — see the file header.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    // Safe under the serial-callback contract documented above.
    private nonisolated(unsafe) var contentHandler: ((UNNotificationContent) -> Void)?
    private nonisolated(unsafe) var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        // The mutable copy we hand back — its body is the generic placeholder
        // until (and unless) we replace it, so this IS the F1 fallback.
        let mutable = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        self.contentHandler = contentHandler
        self.bestAttempt = mutable

        let userInfo = request.content.userInfo
        let roomId = userInfo["room_id"] as? String
        let eventId = userInfo["event_id"] as? String
        let accountId = userInfo["account_id"] as? String

        AppLog.log("🔔 [nse] didReceive room=%@ event=%@ account=%@",
                   roomId ?? "nil", eventId ?? "nil", accountId ?? "nil")

        // (F.2.2 step 1) No references on the payload (Stage F1, or
        // APNS_INCLUDE_EVENT_REF off) → keep the generic body, done.
        guard let roomId, let eventId, !roomId.isEmpty, !eventId.isEmpty else {
            deliver(mutable)
            return
        }
        // Dedupe by event_id (F.2.2): stamp it so a re-delivery reconciles.
        mutable.userInfo["event_id"] = eventId

        // Fetch + local decrypt on the MainActor; only the Sendable `Content`
        // result crosses back. The Task captures ONLY Sendable values (the ids)
        // + `self`; the non-Sendable banner is reached through `self.bestAttempt`
        // (nonisolated(unsafe), safe under the serial-callback contract), never
        // captured directly.
        Task { [roomId, eventId, accountId] in
            let banner = await PushDecryptor.decryptBanner(
                roomId: roomId, eventId: eventId, accountId: accountId
            )
            self.applyAndDeliver(banner)
        }
    }

    /// Apply the decrypted banner (if any) onto the pending content and deliver.
    /// Runs on the Task's context; touches only `self`'s nonisolated(unsafe)
    /// state, which the serial-callback contract makes safe.
    private func applyAndDeliver(_ banner: NotificationContentBuilder.Content?) {
        guard let mutable = bestAttempt else {
            deliver(UNMutableNotificationContent())
            return
        }
        if let banner {
            mutable.title = banner.title
            mutable.body = banner.body
            if let threadId = banner.threadId { mutable.threadIdentifier = threadId }
            AppLog.log("🔔 [nse] decrypted → replaced banner body (len=%ld)", banner.body.count)
        } else {
            AppLog.log("🔔 [nse] keeping generic placeholder (fallback)")
        }
        deliver(mutable)
    }

    /// iOS is about to terminate the extension (it ran past its short wall-clock
    /// budget). Deliver the best we have RIGHT NOW (F.2.2 / F.2.5: best-attempt) —
    /// typically the unmodified generic placeholder.
    override func serviceExtensionTimeWillExpire() {
        AppLog.log("🔔 [nse] serviceExtensionTimeWillExpire — delivering best attempt")
        if let bestAttempt {
            deliver(bestAttempt)
        } else if let handler = contentHandler {
            contentHandler = nil
            handler(UNMutableNotificationContent())
        }
    }

    /// Fire the content handler exactly once.
    private func deliver(_ content: UNNotificationContent) {
        guard let handler = contentHandler else { return }
        contentHandler = nil
        handler(content)
    }
}
