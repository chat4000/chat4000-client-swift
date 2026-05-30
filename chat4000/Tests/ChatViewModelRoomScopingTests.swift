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
        #expect(vm.messages.count == 2)
        #expect(vm.messages.allSatisfy { $0.roomId == "!A" })

        vm.switchRoom(id: "!B")
        #expect(vm.messages.count == 1)
        #expect(vm.messages.first?.roomId == "!B")
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

        let sent = try #require(vm.messages.last)
        #expect(sent.roomId == "!A")
        #expect(sent.sender == .user)
        #expect(sent.text == "hello")
    }
}
