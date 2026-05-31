import Foundation
import Testing
@testable import chat4000

struct SyncModelTests {
    private func event(
        _ type: String,
        stateKey: String? = nil,
        content: [String: Any],
        eventId: String = "$e",
        sender: String = "@plugin:x"
    ) -> [String: Any] {
        var e: [String: Any] = [
            "type": type,
            "content": content,
            "event_id": eventId,
            "sender": sender,
            "origin_server_ts": 1000,
        ]
        if let stateKey { e["state_key"] = stateKey }
        return e
    }

    /// Worth 9 — room classification + member extraction drive the sidebar AND
    /// the E2EE recipient set; getting these wrong breaks sending entirely.
    @Test
    func parsesSessionRoomFields() throws {
        let frame: [String: Any] = [
            "pos": "p1",
            "rooms": [
                "!room:x": [
                    "name": "Deploy",
                    "required_state": [
                        event("chat4000.room_kind", stateKey: "", content: ["kind": "session"]),
                        event("m.room.encryption", stateKey: "", content: ["algorithm": "m.megolm.v1.aes-sha2"]),
                        event("m.room.member", stateKey: "@u:x", content: ["membership": "join"]),
                        event("m.room.member", stateKey: "@plugin:x", content: ["membership": "join"]),
                        event("m.room.member", stateKey: "@gone:x", content: ["membership": "leave"]),
                        event("chat4000.status", stateKey: "", content: ["state": "thinking"]),
                    ],
                    "timeline": [],
                ],
            ],
        ]
        let sync = SyncModel.parse(frame)
        #expect(sync.pos == "p1")
        let room = try #require(sync.rooms.first)
        #expect(room.id == "!room:x")
        #expect(room.name == "Deploy")
        #expect(room.roomKind == "session")
        #expect(room.isEncrypted)
        #expect(!room.isSpace)
        #expect(room.statusState == "thinking")
        // Only joined members; the one who left is excluded.
        #expect(Set(room.members) == ["@u:x", "@plugin:x"])
    }

    /// Worth 7 — a space must be flagged so the sidebar hides it (protocol E).
    @Test
    func flagsSpaceRoom() throws {
        let frame: [String: Any] = [
            "rooms": [
                "!space:x": [
                    "required_state": [
                        event("m.room.create", stateKey: "", content: ["type": "m.space"]),
                    ],
                    "timeline": [],
                ],
            ],
        ]
        let room = try #require(SyncModel.parse(frame).rooms.first)
        #expect(room.isSpace)
    }

    /// Worth 9 — the e2ee extension feeds OlmMachine.receiveSyncChanges; a
    /// mis-parse silently breaks decryption of every subsequent message.
    @Test
    func parsesE2EEExtensions() {
        let frame: [String: Any] = [
            "rooms": [:],
            "extensions": [
                "to_device": ["events": [["type": "m.room.key", "sender": "@p:x", "content": [:]]]],
                "e2ee": [
                    "device_lists": ["changed": ["@p:x"], "left": ["@q:x"]],
                    "device_one_time_keys_count": ["signed_curve25519": 42],
                    "device_unused_fallback_key_types": ["signed_curve25519"],
                ],
            ],
        ]
        let sync = SyncModel.parse(frame)
        #expect(sync.toDevice.count == 1)
        #expect(sync.toDevice.eventsJSON.contains("m.room.key"))
        #expect(sync.deviceLists.changed == ["@p:x"])
        #expect(sync.deviceLists.left == ["@q:x"])
        #expect(sync.oneTimeKeyCounts["signed_curve25519"] == 42)
        #expect(sync.unusedFallbackKeyTypes == ["signed_curve25519"])
    }

    /// Worth 6 — a malformed/empty frame must degrade to empty, never crash.
    @Test
    func toleratesEmptyAndGarbageFrames() {
        let empty = SyncModel.parse([:])
        #expect(empty.pos == nil)
        #expect(empty.rooms.isEmpty)
        #expect(empty.toDevice.count == 0)
        #expect(empty.unusedFallbackKeyTypes == nil)
    }
}
