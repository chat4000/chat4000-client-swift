// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

import Foundation
import Testing
@testable import chat4000

/// Unit tests for `NotificationContentBuilder` — the pure decrypted-event →
/// banner function the NSE will use. Covers each msgtype, `m.replace` edits,
/// `chat4000.html_card`, the tool-transcript drop, and the missing/undecryptable
/// fallback. Kept equivalent to `MatrixSession.maybePostBackgroundNotification`.
struct NotificationContentBuilderTests {
    private func event(_ dict: [String: Any]) -> [String: Any] { dict }

    // MARK: - Text

    @Test
    func plainTextBody() {
        let c = NotificationContentBuilder.build(fromClearEvent: event([
            "type": "m.room.message",
            "content": ["msgtype": "m.text", "body": "hello world"]
        ]))
        #expect(c.body == "hello world")
        #expect(c.title == "chat4000")
        #expect(c.threadId == nil)
    }

    @Test
    func noticeAndEmoteUseBody() {
        let notice = NotificationContentBuilder.build(fromClearEvent: event([
            "type": "m.room.message",
            "content": ["msgtype": "m.notice", "body": "a notice"]
        ]))
        #expect(notice.body == "a notice")

        let emote = NotificationContentBuilder.build(fromClearEvent: event([
            "type": "m.room.message",
            "content": ["msgtype": "m.emote", "body": "waves"]
        ]))
        #expect(emote.body == "waves")
    }

    // MARK: - Edit (m.replace)

    @Test
    func editPrefersNewContentBody() {
        // An m.replace edit: the displayed text is m.new_content.body, NOT the
        // top-level fallback `body` (which by convention is "* <new text>").
        let c = NotificationContentBuilder.build(fromClearEvent: event([
            "type": "m.room.message",
            "content": [
                "msgtype": "m.text",
                "body": "* edited text",
                "m.new_content": ["msgtype": "m.text", "body": "edited text"],
                "m.relates_to": ["rel_type": "m.replace", "event_id": "$orig"]
            ]
        ]))
        #expect(c.body == "edited text")
        #expect(c.threadId == "$orig")
    }

    // MARK: - Media

    @Test
    func imageBody() {
        let c = NotificationContentBuilder.build(fromClearEvent: event([
            "type": "m.room.message",
            "content": ["msgtype": "m.image", "body": "IMG_0001.jpg"]
        ]))
        #expect(c.body == "📷 Photo")
    }

    @Test
    func audioBody() {
        let c = NotificationContentBuilder.build(fromClearEvent: event([
            "type": "m.room.message",
            "content": ["msgtype": "m.audio", "body": "voice.ogg"]
        ]))
        #expect(c.body == "🎤 Voice message")
    }

    // MARK: - html_card

    @Test
    func htmlCardGenericTitleNoHtml() {
        let c = NotificationContentBuilder.build(fromClearEvent: event([
            "type": "chat4000.html_card",
            "content": ["html": "<h1>secret stuff</h1><script>x()</script>"]
        ]))
        #expect(c.title == "chat4000")
        #expect(c.body == "Sent you a card")
        // No html ever leaks into the banner.
        #expect(c.body.contains("<") == false)
    }

    // MARK: - Tool transcript → fallback

    @Test
    func toolTranscriptDropsToFallback() {
        let c = NotificationContentBuilder.build(fromClearEvent: event([
            "type": "m.room.message",
            "content": [
                "msgtype": "m.text",
                // Real tool narration format: <prefix> <toolname>: … (the tool name
                // is the SECOND token, mirroring the in-app "📚 skill_view: …" leak).
                "body": "📚 skill_view: reading docs\n💻 terminal: ls -la\n🔍 file_search..."
            ]
        ]))
        #expect(c == NotificationContentBuilder.fallback)
        #expect(c.body == "New message")
        #expect(c.title == "chat4000")
    }

    @Test
    func mixedRealMessageIsNotDroppedAsTool() {
        // A real message that merely mentions a tool name is NOT a pure transcript.
        let c = NotificationContentBuilder.build(fromClearEvent: event([
            "type": "m.room.message",
            "content": ["msgtype": "m.text", "body": "I ran bash and here is the answer to your question"]
        ]))
        #expect(c.body == "I ran bash and here is the answer to your question")
    }

    // MARK: - Fallback cases

    @Test
    func missingContentIsFallback() {
        let c = NotificationContentBuilder.build(fromClearEvent: event(["type": "m.room.message"]))
        #expect(c == NotificationContentBuilder.fallback)
    }

    @Test
    func emptyBodyIsFallback() {
        let c = NotificationContentBuilder.build(fromClearEvent: event([
            "type": "m.room.message",
            "content": ["msgtype": "m.text", "body": ""]
        ]))
        #expect(c == NotificationContentBuilder.fallback)
    }

    @Test
    func unknownMsgtypeIsFallback() {
        let c = NotificationContentBuilder.build(fromClearEvent: event([
            "type": "m.room.message",
            "content": ["msgtype": "m.file", "body": "doc.pdf"]
        ]))
        #expect(c == NotificationContentBuilder.fallback)
    }

    @Test
    func undecryptableJSONStringIsFallback() {
        let c = NotificationContentBuilder.build(fromClearEventJSON: "{ this is not json")
        #expect(c == NotificationContentBuilder.fallback)
    }

    @Test
    func validJSONStringPathParses() {
        let json = #"{"type":"m.room.message","content":{"msgtype":"m.text","body":"via string"}}"#
        let c = NotificationContentBuilder.build(fromClearEventJSON: json)
        #expect(c.body == "via string")
    }
}
