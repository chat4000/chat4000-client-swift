import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Parse the gateway `sync` frame (protocol D.1 + simplified-MSC3575
// sliding sync) into typed, Sendable values that two consumers need:
//   1. CryptoEngine — the e2ee inputs for `OlmMachine.receiveSyncChanges`
//      (to-device events, device-list changes, one-time-key counts, unused
//      fallback key types, the `pos` cursor as next-batch token).
//   2. The room/timeline layer — rooms with their name/kind/encryption/space
//      flags plus the raw timeline + required-state events (kept as raw JSON
//      strings so the turn/tool/status mapping, protocol E, can extract
//      `content`, `m.relates_to`, and `chat4000.push` itself).
// ─────────────────────────────────────────────────────────────────────────────

/// One parsed gateway `sync` frame.
struct GatewaySync: Sendable {
    /// Sliding-sync cursor; replayed as `sync_start.pos` and fed to the crypto
    /// machine as `next_batch`.
    var pos: String?
    var rooms: [SyncRoom]
    var toDevice: ToDeviceBatch
    var deviceLists: SyncDeviceLists
    /// `extensions.e2ee.device_one_time_keys_count` — algorithm → count.
    var oneTimeKeyCounts: [String: Int32]
    /// `extensions.e2ee.device_unused_fallback_key_types` — nil when the key is
    /// absent (distinct from an empty list, which the machine treats as "all
    /// fallback keys used").
    var unusedFallbackKeyTypes: [String]?
    /// `extensions.receipts` — m.read / m.read.private markers, used to drive the
    /// "read" tick on our outbound messages.
    var receipts: [ReadReceipt]
}

/// One read marker: `userId` read up to `eventId` in `roomId`.
struct ReadReceipt: Sendable, Equatable {
    var roomId: String
    var userId: String
    var eventId: String
}

/// `extensions.e2ee.device_lists` — users whose device list changed / who left.
struct SyncDeviceLists: Sendable, Equatable {
    var changed: [String]
    var left: [String]

    static let empty = SyncDeviceLists(changed: [], left: [])
}

/// `extensions.to_device.events`, re-serialized as the JSON object string
/// `OlmMachine.receiveSyncChanges(events:)` expects: a ruma `ToDevice` object
/// `{"events":[...]}` — NOT a bare array. The FFI does
/// `serde_json::from_str::<ToDevice>(events)`, and `ToDevice.events` has
/// `#[serde(default)]`, so a bare `[]` decodes fine (defaults to empty) but a
/// bare `[{event}]` is read positionally and throws
/// "invalid type: map, expected a sequence" — which silently broke ALL inbound
/// to-device key delivery. Always wrap in `{"events":[...]}`.
struct ToDeviceBatch: Sendable, Equatable {
    var eventsJSON: String
    var count: Int

    static let empty = ToDeviceBatch(eventsJSON: #"{"events":[]}"#, count: 0)
}

/// One room from the sync `rooms` map, with chat4000-relevant fields lifted out
/// of its `required_state`.
struct SyncRoom: Sendable, Identifiable, Equatable {
    var id: String
    /// `m.room.name` (or the sliding-sync top-level `name`), best-effort.
    var name: String?
    /// `chat4000.room_kind` → `"control"` | `"session"` (protocol E). nil when
    /// the state event is absent (treated as a normal session by the consumer).
    var roomKind: String?
    /// True when `m.room.create` declares `type == "m.space"` — the plugin's
    /// space, hidden from the sidebar.
    var isSpace: Bool
    /// True when `m.room.encryption` is present (drives `setRoomAlgorithm`).
    var isEncrypted: Bool
    /// True when the room carries sliding-sync `invite_state` — i.e. we're
    /// invited but not joined. The client auto-joins these so the control /
    /// session rooms surface with full state (they otherwise never appear,
    /// since the list only shows joined rooms).
    var isInvite: Bool
    /// Joined member MXIDs from `m.room.member` state — the recipient set for
    /// sharing the megolm room key (CryptoEngine.shareRoomKey) and tracking.
    var members: [String]
    /// Latest `chat4000.status` state value (`thinking`/`working`/`typing`/
    /// `idle`, protocol E), if present.
    var statusState: String?
    /// Sliding-sync unread/notification count, best-effort (0 when absent).
    var notificationCount: Int
    /// Timeline events in arrival order (each kept as raw JSON, see `SyncEvent`).
    var timeline: [SyncEvent]
    /// `required_state` events requested in the sliding-sync list.
    var requiredState: [SyncEvent]
}

/// A single Matrix event from a room timeline or state, with the common
/// envelope fields lifted out and the full event retained as raw JSON so
/// downstream code can read `content`, `m.relates_to`, `chat4000.push`, etc.
/// without this layer having to model every event type.
struct SyncEvent: Sendable, Equatable {
    var type: String
    var eventId: String?
    var sender: String?
    /// Present for state events ("" for the canonical state key).
    var stateKey: String?
    var originServerTs: Int64?
    /// The complete event object, re-serialized to JSON.
    var rawJSON: String
}

enum SyncModel {
    /// Parse a decoded gateway `sync` frame (the top-level object with `pos`,
    /// `rooms`, `extensions`). Defensive: any missing/oddly-typed field degrades
    /// to an empty default rather than throwing — a malformed sync should never
    /// crash the client, and the crypto machine tolerates empty batches.
    static func parse(_ frame: [String: Any]) -> GatewaySync {
        let pos = frame["pos"] as? String
        let extensions = frame["extensions"] as? [String: Any] ?? [:]

        return GatewaySync(
            pos: pos,
            rooms: parseRooms(frame["rooms"] as? [String: Any] ?? [:]),
            toDevice: parseToDevice(extensions["to_device"] as? [String: Any]),
            deviceLists: parseDeviceLists(extensions["e2ee"] as? [String: Any]),
            oneTimeKeyCounts: parseOTKCounts(extensions["e2ee"] as? [String: Any]),
            unusedFallbackKeyTypes: parseFallbackKeyTypes(extensions["e2ee"] as? [String: Any]),
            receipts: parseReceipts(extensions["receipts"] as? [String: Any])
        )
    }

    // MARK: - Rooms

    private static func parseRooms(_ rooms: [String: Any]) -> [SyncRoom] {
        rooms.compactMap { id, value in
            guard let room = value as? [String: Any] else { return nil }
            return parseRoom(id: id, room: room)
        }
    }

    private static func parseRoom(id: String, room: [String: Any]) -> SyncRoom {
        let requiredState = parseEvents(room["required_state"])
        let timeline = parseEvents(room["timeline"])

        var roomKind: String?
        var isSpace = false
        var isEncrypted = false
        var stateName: String?
        var statusState: String?
        var members: [String] = []

        for event in requiredState {
            switch event.type {
            case "chat4000.room_kind":
                roomKind = stringField(event.rawJSON, path: ["content", "kind"])
            case "chat4000.status":
                statusState = stringField(event.rawJSON, path: ["content", "state"])
            case "m.room.encryption":
                isEncrypted = true
            case "m.room.create":
                if stringField(event.rawJSON, path: ["content", "type"]) == "m.space" {
                    isSpace = true
                }
            case "m.room.name":
                stateName = stringField(event.rawJSON, path: ["content", "name"])
            case "m.room.member":
                // state_key is the member's MXID; include only joined members.
                if stringField(event.rawJSON, path: ["content", "membership"]) == "join",
                   let mxid = event.stateKey, !mxid.isEmpty {
                    members.append(mxid)
                }
            default:
                break
            }
        }

        return SyncRoom(
            id: id,
            name: (room["name"] as? String) ?? stateName,
            roomKind: roomKind,
            isSpace: isSpace,
            isEncrypted: isEncrypted,
            isInvite: room["invite_state"] != nil,
            members: members,
            statusState: statusState,
            notificationCount: intField(room["notification_count"]) ?? 0,
            timeline: timeline,
            requiredState: requiredState
        )
    }

    private static func parseEvents(_ value: Any?) -> [SyncEvent] {
        guard let array = value as? [[String: Any]] else { return [] }
        return array.compactMap(parseEvent)
    }

    private static func parseEvent(_ event: [String: Any]) -> SyncEvent? {
        guard let type = event["type"] as? String else { return nil }
        return SyncEvent(
            type: type,
            eventId: event["event_id"] as? String,
            sender: event["sender"] as? String,
            stateKey: event["state_key"] as? String,
            originServerTs: intField(event["origin_server_ts"]).map(Int64.init),
            rawJSON: jsonString(event) ?? "{}"
        )
    }

    // MARK: - Extensions (e2ee / to_device)

    private static func parseToDevice(_ toDevice: [String: Any]?) -> ToDeviceBatch {
        guard let events = toDevice?["events"] as? [[String: Any]], !events.isEmpty else {
            return .empty
        }
        // Wrap as a ruma `ToDevice` object `{"events":[...]}` (see ToDeviceBatch).
        return ToDeviceBatch(eventsJSON: jsonString(["events": events]) ?? #"{"events":[]}"#, count: events.count)
    }

    private static func parseDeviceLists(_ e2ee: [String: Any]?) -> SyncDeviceLists {
        guard let lists = e2ee?["device_lists"] as? [String: Any] else { return .empty }
        return SyncDeviceLists(
            changed: lists["changed"] as? [String] ?? [],
            left: lists["left"] as? [String] ?? []
        )
    }

    private static func parseOTKCounts(_ e2ee: [String: Any]?) -> [String: Int32] {
        guard let counts = e2ee?["device_one_time_keys_count"] as? [String: Any] else { return [:] }
        var out: [String: Int32] = [:]
        for (algorithm, value) in counts {
            if let n = intField(value) { out[algorithm] = Int32(clamping: n) }
        }
        return out
    }

    private static func parseFallbackKeyTypes(_ e2ee: [String: Any]?) -> [String]? {
        // Absent → nil (machine: "unknown"); present (even empty) → the list.
        e2ee?["device_unused_fallback_key_types"] as? [String]
    }

    /// `extensions.receipts.rooms[roomId]` is an `m.receipt` EDU:
    /// `{ content: { "<eventId>": { "m.read"|"m.read.private": { "<user>": {ts} } } } }`.
    /// Some servers nest under `content`, some put the map directly — handle both.
    private static func parseReceipts(_ receipts: [String: Any]?) -> [ReadReceipt] {
        guard let rooms = receipts?["rooms"] as? [String: Any] else { return [] }
        var out: [ReadReceipt] = []
        for (roomId, value) in rooms {
            let edu = value as? [String: Any] ?? [:]
            let content = (edu["content"] as? [String: Any]) ?? edu
            for (eventId, receiptTypes) in content {
                guard eventId.hasPrefix("$"), let types = receiptTypes as? [String: Any] else { continue }
                for kind in ["m.read", "m.read.private"] {
                    guard let users = types[kind] as? [String: Any] else { continue }
                    for userId in users.keys {
                        out.append(ReadReceipt(roomId: roomId, userId: userId, eventId: eventId))
                    }
                }
            }
        }
        return out
    }

    // MARK: - Small helpers

    /// Read a nested string at `content.kind`-style paths from a raw event JSON.
    private static func stringField(_ rawJSON: String, path: [String]) -> String? {
        guard let data = rawJSON.data(using: .utf8),
              var node = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in path.dropLast() {
            guard let next = node[key] as? [String: Any] else { return nil }
            node = next
        }
        return path.last.flatMap { node[$0] as? String }
    }

    /// JSON numbers arrive as `Int`, `Double`, or `NSNumber` depending on the
    /// serializer; normalize to `Int`.
    private static func intField(_ value: Any?) -> Int? {
        switch value {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        case let d as Double: return Int(d)
        case let s as String: return Int(s)
        default: return nil
        }
    }

    private static func jsonString(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
