import Foundation
import Testing
import SwiftData
@testable import chat4000

@MainActor
struct ChatViewModelRoomScopingTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: ChatMessage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// Worth 9 — the core correctness of the multi-session sidebar: switching
    /// rooms must show only that room's messages, never a mix.
    @Test
    func switchRoomScopesMessagesToActiveRoom() throws {
        let ctx = try makeContext()
        let vm = ChatViewModel()
        vm.attach(modelContext: ctx)

        ctx.insert(ChatMessage(text: "a1", sender: .user, roomId: "!A"))
        ctx.insert(ChatMessage(text: "a2", sender: .user, roomId: "!A"))
        ctx.insert(ChatMessage(text: "b1", sender: .user, roomId: "!B"))
        try ctx.save()

        vm.switchRoom(id: "!A")
        let roomA = try #require(vm.frontRoom)
        #expect(roomA.roomId == "!A")
        #expect(roomA.messages.count == 2)
        #expect(roomA.messages.allSatisfy { $0.roomId == "!A" })

        vm.switchRoom(id: "!B")
        let roomB = try #require(vm.frontRoom)
        #expect(roomB.roomId == "!B")
        #expect(roomB.messages.count == 1)
        #expect(roomB.messages.first?.roomId == "!B")
    }

    @Test
    func selectingAlreadyActiveSessionReconcilesVisibleRoom() throws {
        let ctx = try makeContext()
        let vm = ChatViewModel()
        vm.attach(modelContext: ctx)

        ctx.insert(ChatMessage(text: "saved", sender: .agent, roomId: "!A"))
        try ctx.save()

        vm.switchRoom(id: "!A")
        vm.clearActiveRoom()
        vm.switchRoom(id: "!A")

        let room = try #require(vm.frontRoom)
        #expect(room.roomId == "!A")
        #expect(room.messages.map(\.text) == ["saved"])
    }

    @Test
    func syncActiveRoomFromSessionReconcilesVisibleRoom() throws {
        let ctx = try makeContext()
        let vm = ChatViewModel()
        vm.attach(modelContext: ctx)

        ctx.insert(ChatMessage(text: "restored", sender: .agent, roomId: "!A"))
        try ctx.save()

        vm.matrixSession.selectRoom("!A")
        vm.clearActiveRoom()
        vm.syncActiveRoomFromSession()

        let room = try #require(vm.frontRoom)
        #expect(room.roomId == "!A")
        #expect(room.messages.map(\.text) == ["restored"])
    }

    /// Worth 8 — an unstamped (nil-room) message vanishes under the scoped
    /// load, so sends must carry the active room id.
    @Test
    func sendStampsActiveRoom() throws {
        let ctx = try makeContext()
        let vm = ChatViewModel()
        vm.attach(modelContext: ctx)
        vm.switchRoom(id: "!A")

        vm.send(text: "hello")

        let sent = try #require(vm.frontRoom?.messages.last)
        #expect(sent.roomId == "!A")
        #expect(sent.sender == .user)
        #expect(sent.text == "hello")
    }

    @Test
    func redeliveredStreamEventDoesNotDuplicatePersistedRow() throws {
        let ctx = try makeContext()
        let session = MatrixSession()
        let first = RoomViewModel(roomId: "!A", session: session)
        first.attach(modelContext: ctx)

        first.ingest(Self.textEvent(
            eventId: "$root",
            body: "Hi",
            push: false
        ), live: true)
        first.ingest(Self.editEvent(
            eventId: "$edit",
            rootEventId: "$root",
            body: "Hi! How can I help?",
            push: true
        ), live: true)
        #expect(first.messages.map(\.msgId) == ["$root"])
        #expect(first.messages.first?.text == "Hi! How can I help?")

        let second = RoomViewModel(roomId: "!A", session: session)
        second.attach(modelContext: ctx)
        second.ingest(Self.textEvent(
            eventId: "$root",
            body: "Hi",
            push: false
        ), live: true)

        #expect(second.messages.map(\.msgId) == ["$root"])
    }

    @Test
    func loadHistoryDeduplicatesStoredMsgIds() throws {
        let ctx = try makeContext()
        ctx.insert(ChatMessage(msgId: "$dup", text: "one", sender: .agent, roomId: "!A"))
        ctx.insert(ChatMessage(msgId: "$dup", text: "two", sender: .agent, roomId: "!A"))
        try ctx.save()

        let room = RoomViewModel(roomId: "!A", session: MatrixSession())
        room.attach(modelContext: ctx)

        #expect(room.messages.map(\.msgId) == ["$dup"])

        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.roomId == "!A" && $0.msgId == "$dup" }
        )
        #expect((try? ctx.fetch(descriptor).count) == 1)
    }

    @Test
    func sameMsgIdAllowedAcrossRoomsButBlockedWithinRoom() throws {
        let ctx = try makeContext()
        let session = MatrixSession()
        let roomA = RoomViewModel(roomId: "!A", session: session)
        let roomB = RoomViewModel(roomId: "!B", session: session)
        roomA.attach(modelContext: ctx)
        roomB.attach(modelContext: ctx)

        roomA.ingest(Self.textEvent(eventId: "$same", body: "A", push: true), live: true)
        roomB.ingest(Self.textEvent(eventId: "$same", body: "B", push: true), live: true)
        roomA.ingest(Self.textEvent(eventId: "$same", body: "A duplicate", push: true), live: true)

        #expect(roomA.messages.map(\.text) == ["A"])
        #expect(roomB.messages.map(\.text) == ["B"])

        let roomADescriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.roomId == "!A" && $0.msgId == "$same" }
        )
        let roomBDescriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.roomId == "!B" && $0.msgId == "$same" }
        )
        #expect((try? ctx.fetch(roomADescriptor).count) == 1)
        #expect((try? ctx.fetch(roomBDescriptor).count) == 1)
    }

    @Test
    func undecryptableEncryptedMessageShowsUnavailableThenReplaces() throws {
        let ctx = try makeContext()
        let room = RoomViewModel(roomId: "!A", session: MatrixSession())
        room.attach(modelContext: ctx)

        room.ingest(Self.undecryptableEvent(eventId: "$old", push: true), live: false)

        #expect(room.messages.count == 1)
        #expect(room.messages.first?.msgId == "$old")
        #expect(room.messages.first?.kind == .unavailable)
        #expect(room.messages.first?.text == "Message unavailable on this device")

        room.ingest(Self.textEvent(eventId: "$old", body: "Readable now", push: true), live: false)

        #expect(room.messages.count == 1)
        #expect(room.messages.first?.msgId == "$old")
        #expect(room.messages.first?.kind == .message)
        #expect(room.messages.first?.text == "Readable now")
    }

    @Test
    func undecryptableNonPushFrameStaysHidden() throws {
        let ctx = try makeContext()
        let room = RoomViewModel(roomId: "!A", session: MatrixSession())
        room.attach(modelContext: ctx)

        room.ingest(Self.undecryptableEvent(eventId: "$status", push: false), live: false)

        #expect(room.messages.isEmpty)
    }

    @Test
    func toolTranscriptTextIsDroppedButToolChipStays() throws {
        let ctx = try makeContext()
        let room = RoomViewModel(roomId: "!A", session: MatrixSession())
        room.attach(modelContext: ctx)

        room.ingest(Self.textEvent(
            eventId: "$transcript",
            body: """
            📚 skill_view: quick-news-briefings
            🌐 browser_navigate: https://www.ynet.co.il
            🖥️ browser_console...
            """,
            push: false
        ), live: true)
        room.ingest(Self.toolEvent(
            eventId: "$tool",
            toolId: "tool-1",
            name: "skill_view",
            icon: "📚"
        ), live: true)

        #expect(room.messages.count == 1)
        #expect(room.messages.first?.kind == .toolCall)
        #expect(room.messages.first?.toolName == "skill_view")
    }

    @Test
    func loadHistoryDeletesStoredToolTranscriptText() throws {
        let ctx = try makeContext()
        ctx.insert(ChatMessage(
            msgId: "$bad",
            text: """
            📚 skill_view: quick-news-briefings
            🌐 browser_navigate: https://www.ynet.co.il
            """,
            sender: .agent,
            roomId: "!A"
        ))
        ctx.insert(ChatMessage(msgId: "$good", text: "Ynet top headlines:", sender: .agent, roomId: "!A"))
        try ctx.save()

        let room = RoomViewModel(roomId: "!A", session: MatrixSession())
        room.attach(modelContext: ctx)

        #expect(room.messages.map(\.msgId) == ["$good"])
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.roomId == "!A" && $0.msgId == "$bad" }
        )
        #expect((try? ctx.fetch(descriptor).count) == 0)
    }

    @Test
    func htmlLookingTextMessageIsNotSniffedAsCard() throws {
        let ctx = try makeContext()
        let room = RoomViewModel(roomId: "!A", session: MatrixSession())
        room.attach(modelContext: ctx)

        let body = "<article><p>plain text, not a card</p></article>"
        room.ingest(Self.textEvent(eventId: "$html-text", body: body, push: true), live: true)

        let message = try #require(room.messages.first)
        #expect(room.messages.count == 1)
        #expect(message.kind == .message)
        #expect(message.text == body)
        #expect(message.htmlCardHTML == nil)
    }

    @Test
    func htmlCardStoresAuthoredHTMLFromCustomType() throws {
        let ctx = try makeContext()
        let room = RoomViewModel(roomId: "!A", session: MatrixSession())
        room.attach(modelContext: ctx)

        let html = """
        <article onclick="bad()">
          <script>bad()</script>
          <p onclick="bad()">Safe</p>
          <a href="java
        script:alert(1)">link</a>
          <img src="https://example.test/card.png">
          <iframe src="https://example.test"></iframe>
        </article>
        """
        room.ingest(Self.htmlCardEvent(eventId: "$card", html: html), live: true)

        let message = try #require(room.messages.first)
        let authoredHTML = try #require(message.htmlCardHTML)
        let lowercased = authoredHTML.lowercased()
        #expect(room.messages.count == 1)
        #expect(message.kind == .htmlCard)
        #expect(message.text.isEmpty)
        #expect(authoredHTML == html)
        #expect(authoredHTML.contains("Safe"))
        #expect(authoredHTML.contains("link"))
        #expect(lowercased.contains("script"))
        #expect(lowercased.contains("onclick"))
        #expect(lowercased.contains("<img"))
        #expect(lowercased.contains("<iframe"))
        #expect(lowercased.contains("href="))
    }

    @Test
    func htmlCardPreservesPriorStreamedTextAndAppendsCard() throws {
        // A real agent turn is often [streamed text answer] + [final_card] (the
        // weather flow: a sentence PLUS the glanceable card). The card must NOT
        // silently delete the preceding text — the only way to abandon a stream is an
        // explicit `text_end reset=true` (protocol §6.4.2). The old behaviour deleted
        // the open stream on every card, which is exactly why a real text answer
        // "never showed up" on catch-up / cross-device replay. Both must survive.
        let ctx = try makeContext()
        let room = RoomViewModel(roomId: "!A", session: MatrixSession())
        room.attach(modelContext: ctx)

        room.ingest(Self.textEvent(eventId: "$stream", body: "partial answer", push: false), live: true)
        room.ingest(Self.htmlCardEvent(eventId: "$card", html: "<article><p>Final card</p></article>"), live: true)

        #expect(room.messages.count == 2)
        let text = try #require(room.messages.first { $0.kind == .message })
        #expect(text.text == "partial answer")
        let card = try #require(room.messages.first { $0.kind == .htmlCard })
        #expect(card.msgId == "$card")
        #expect(card.htmlCardHTML?.contains("Final card") == true)
    }

    @Test
    func timelineRendersInOriginServerTsOrderNotDeliveryOrder() throws {
        // Protocol §6.4.2: rendering follows wall-clock `ts`, NOT socket delivery
        // order. A live catch-up sync delivers a room's backlog scrambled; the client
        // must still show it chronologically. Deliver three finalized texts whose ts
        // are out of order and assert the rendered order is by ts.
        let ctx = try makeContext()
        let room = RoomViewModel(roomId: "!A", session: MatrixSession())
        room.attach(modelContext: ctx)

        room.ingest(Self.textEvent(eventId: "$b", body: "second", push: true, ts: 2000), live: true)
        room.ingest(Self.textEvent(eventId: "$c", body: "third", push: true, ts: 3000), live: true)
        room.ingest(Self.textEvent(eventId: "$a", body: "first", push: true, ts: 1000), live: true)

        #expect(room.messages.map(\.text) == ["first", "second", "third"])
    }

    @Test
    func htmlCardDeduplicatesByEventId() throws {
        let ctx = try makeContext()
        let room = RoomViewModel(roomId: "!A", session: MatrixSession())
        room.attach(modelContext: ctx)

        room.ingest(Self.htmlCardEvent(eventId: "$card", html: "<p>One</p>"), live: true)
        room.ingest(Self.htmlCardEvent(eventId: "$card", html: "<p>Two</p>"), live: true)

        let message = try #require(room.messages.first)
        #expect(room.messages.count == 1)
        #expect(message.kind == .htmlCard)
        #expect(message.htmlCardHTML?.contains("One") == true)
    }

    private static func undecryptableEvent(eventId: String, push: Bool) -> DecryptedRoomEvent {
        DecryptedRoomEvent(
            outer: SyncEvent(
                type: "m.room.encrypted",
                eventId: eventId,
                sender: "@plugin:x",
                stateKey: nil,
                originServerTs: 1,
                rawJSON: #"{"content":{"chat4000.push":\#(push)}}"#
            ),
            clear: nil,
            isOwn: false
        )
    }

    private static func textEvent(eventId: String, body: String, push: Bool, ts: Int64 = 1) -> DecryptedRoomEvent {
        DecryptedRoomEvent(
            outer: SyncEvent(
                type: "m.room.encrypted",
                eventId: eventId,
                sender: "@plugin:x",
                stateKey: nil,
                originServerTs: ts,
                rawJSON: #"{"content":{"chat4000.push":\#(push)}}"#
            ),
            clear: #"{"type":"m.room.message","content":{"msgtype":"m.text","body":\#(jsonStringLiteral(body))}}"#,
            isOwn: false
        )
    }

    private static func htmlCardEvent(eventId: String, html: String, push: Bool = true) -> DecryptedRoomEvent {
        DecryptedRoomEvent(
            outer: SyncEvent(
                type: "m.room.encrypted",
                eventId: eventId,
                sender: "@plugin:x",
                stateKey: nil,
                originServerTs: 1,
                rawJSON: #"{"content":{"chat4000.push":\#(push)}}"#
            ),
            clear: #"{"type":"chat4000.html_card","content":{"html":\#(jsonStringLiteral(html))}}"#,
            isOwn: false
        )
    }

    private static func toolEvent(eventId: String, toolId: String, name: String, icon: String) -> DecryptedRoomEvent {
        DecryptedRoomEvent(
            outer: SyncEvent(
                type: "m.room.encrypted",
                eventId: eventId,
                sender: "@plugin:x",
                stateKey: nil,
                originServerTs: 1,
                rawJSON: #"{"content":{"chat4000.push":false}}"#
            ),
            clear: """
            {"type":"m.room.message","content":{"msgtype":"chat4000.tool","chat4000.tool":{"tool_id":\(jsonStringLiteral(toolId)),"name":\(jsonStringLiteral(name)),"icon":\(jsonStringLiteral(icon))}}}
            """,
            isOwn: false
        )
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return #""""#
        }
        return literal
    }

    private static func editEvent(eventId: String, rootEventId: String, body: String, push: Bool) -> DecryptedRoomEvent {
        DecryptedRoomEvent(
            outer: SyncEvent(
                type: "m.room.encrypted",
                eventId: eventId,
                sender: "@plugin:x",
                stateKey: nil,
                originServerTs: 2,
                rawJSON: """
                {"content":{"chat4000.push":\(push),"m.relates_to":{"rel_type":"m.replace","event_id":"\(rootEventId)"}}}
                """
            ),
            clear: """
            {"type":"m.room.message","content":{"msgtype":"m.text","body":"* \(body)","m.new_content":{"msgtype":"m.text","body":"\(body)"}}}
            """,
            isOwn: false
        )
    }
}
