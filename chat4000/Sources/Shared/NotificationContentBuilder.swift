// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// NotificationContentBuilder — pure, dependency-free banner text from a decrypted
// event.
//
// WHY (foundation for the iOS Notification Service Extension, F2): when the NSE
// decrypts an inbound `m.room.encrypted` event it must turn the cleartext into a
// user-facing banner WITHOUT touching SwiftData, the view models, or the live
// sync path. This enum is that pure function — `decrypted event → (title, body,
// threadId)` — and is a faithful mirror of the in-app banner logic in
// `MatrixSession.maybePostBackgroundNotification` so the two render identically.
//
// PURITY: no I/O, no actor, no app singletons. It takes either the cleartext
// JSON string or an already-parsed dict, so it is trivially unit-testable and
// safe to call from the extension process. It NEVER throws — anything it can't
// make sense of degrades to the generic ("chat4000" / "New message") fallback.
//
// DELIBERATE DUPLICATION: the tool-transcript predicate is duplicated from
// `RoomViewModel.isPureToolTranscript` (kept byte-for-byte equivalent) rather than
// referenced, so this builder pulls in NOTHING from the main-app view layer and
// can ship inside the NSE target later with no extra dependencies. The defense is
// the same one the in-app path uses (Bug 2): tool narration that leaks from the
// plugin as push-eligible `m.text` must never wake the user.
// ─────────────────────────────────────────────────────────────────────────────

enum NotificationContentBuilder {
    /// The banner pieces. `threadId` groups related banners in Notification Center
    /// (UNNotificationContent.threadIdentifier); nil means "ungrouped".
    struct Content: Equatable {
        let title: String
        let body: String
        let threadId: String?
    }

    /// Generic, always-safe fallback used when content is missing, undecryptable,
    /// or a type we don't render in a banner.
    static let fallback = Content(title: "chat4000", body: "New message", threadId: nil)

    /// Build banner content from the DECRYPTED event JSON string (the cleartext
    /// event, `{"type":…,"content":{…}}`). Unparseable → fallback.
    static func build(fromClearEventJSON json: String) -> Content {
        guard let data = json.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return fallback }
        return build(fromClearEvent: event)
    }

    /// Build banner content from an already-parsed decrypted event dict.
    /// `event` is the full cleartext event (has `type` and `content`).
    static func build(fromClearEvent event: [String: Any]) -> Content {
        guard let content = event["content"] as? [String: Any] else { return fallback }

        let type = event["type"] as? String
        let threadId = threadIdentifier(content: content)

        // chat4000.html_card is an event TYPE (not an msgtype). Per product, the
        // banner shows a generic title with NO html — the card renders only inside
        // the app.
        if type == "chat4000.html_card" {
            return Content(title: "chat4000", body: "Sent you a card", threadId: threadId)
        }

        // Everything else is a room message keyed by msgtype, mirroring
        // maybePostBackgroundNotification.
        switch content["msgtype"] as? String {
        case "m.text", "m.notice", "m.emote":
            // `m.replace` edits carry the new text under `m.new_content.body`;
            // otherwise the top-level `body`.
            let newContent = content["m.new_content"] as? [String: Any]
            let raw = (newContent?["body"] as? String) ?? (content["body"] as? String)
            guard let body = raw, !body.isEmpty else { return fallback }
            // Drop pure tool-transcript narration → generic fallback rather than
            // surfacing "📚 skill_view: …" to the user.
            if isPureToolTranscript(body) {
                return fallback
            }
            return Content(title: "chat4000", body: body, threadId: threadId)

        case "m.image":
            return Content(title: "chat4000", body: "📷 Photo", threadId: threadId)

        case "m.audio":
            return Content(title: "chat4000", body: "🎤 Voice message", threadId: threadId)

        default:
            // Tool/status/other msgtypes, or none → no specific banner.
            return fallback
        }
    }

    // MARK: - Thread grouping

    /// Derive the Notification Center grouping id from the cleartext
    /// `m.relates_to` (a thread/edit/reply relation points at a parent event).
    /// Nil when there is no relation — callers may then group by room.
    private static func threadIdentifier(content: [String: Any]) -> String? {
        guard let relates = content["m.relates_to"] as? [String: Any] else { return nil }
        // Threaded messages relate via `event_id`; an edit's `m.replace` also
        // carries the parent event id. Either makes a stable grouping key.
        return relates["event_id"] as? String
    }

    // MARK: - Tool-transcript predicate (duplicated from RoomViewModel)
    //
    // Kept equivalent to `RoomViewModel.isPureToolTranscript`. A body is a "pure
    // tool transcript" when every non-empty line looks like tool-activity
    // narration ("toolname: …" / "toolname…"). Such bodies must never become a
    // banner.

    static func isPureToolTranscript(_ text: String) -> Bool {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy(isToolTranscriptLine(_:))
    }

    private static func isToolTranscriptLine(_ line: String) -> Bool {
        let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2 else { return false }

        let rest = String(parts[1])
        guard let nameEnd = rest.firstIndex(where: isToolNameTerminator(_:)) else {
            return false
        }

        let name = String(rest[..<nameEnd])
        guard isLikelyToolName(name) else { return false }

        let suffix = String(rest[nameEnd...])
        return suffix.hasPrefix(":") || suffix.hasPrefix("...")
    }

    private static func isToolNameTerminator(_ character: Character) -> Bool {
        character == ":" || character == "." || character.isWhitespace
    }

    private static func isLikelyToolName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let knownSimpleNames: Set<String> = ["bash", "python", "terminal", "todo", "cronjob"]
        if knownSimpleNames.contains(name) { return true }
        return name.contains("_") || name.contains(".") || name.contains("-")
    }
}
