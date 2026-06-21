import Foundation
import Testing
import SwiftData
@testable import chat4000

/// Protocol D.1 two-cursor sliding sync (crash-safe to-device key delivery).
/// Sliding sync has TWO independent server-side cursors per device: the room
/// cursor (`pos`) and the to-device cursor (`to_device_pos`). The to-device
/// cursor carries the Olm-wrapped Megolm room keys and is delete-on-read, so
/// acking it before its keys are durably saved permanently loses those keys
/// (UTD). These tests pin the client's three responsibilities:
///   • READ  — parse the frame's top-level `to_device_pos` (SyncModel).
///   • DECIDE — advance the cursor only when its keys are durably persisted, and
///     carry the last good value forward otherwise (MatrixSession.resolveToDevicePos).
///   • SEND  — echo it in `sync_ack` and resume it in `sync_start`
///     (GatewayClient.syncAckFrame / .syncStartFrame).
struct TwoCursorSyncTests {

    // MARK: - READ: parse `to_device_pos` from the sync frame

    @Test func parseExtractsToDevicePosWhenPresent() {
        let frame: [String: Any] = ["pos": "R1", "to_device_pos": "T7", "rooms": [:], "extensions": [:]]
        let sync = SyncModel.parse(frame)
        #expect(sync.pos == "R1")
        #expect(sync.toDevicePos == "T7")
    }

    @Test func parseToDevicePosNilWhenAbsent() {
        // A batch with no to-device delivery carries no `to_device_pos`; the two
        // cursors advance on separate clocks, so `pos` present + to-device absent
        // is the common case.
        let frame: [String: Any] = ["pos": "R2", "rooms": [:], "extensions": [:]]
        let sync = SyncModel.parse(frame)
        #expect(sync.pos == "R2")
        #expect(sync.toDevicePos == nil)
    }

    // MARK: - DECIDE: when to advance / persist the to-device cursor
    // (resolveToDevicePos) — (a) advance-with-keys, (c) carry-forward, (e) never
    // advance past unsaved keys.

    /// (a) Keys durably persisted (crypto store committed) AND the frame advanced
    /// the cursor → adopt the frame's cursor. This is the only path that advances:
    /// the cursor is never persisted/acked ahead of its keys.
    @Test func advancesWhenKeysPersistedAndFrameHasCursor() {
        #expect(MatrixSession.resolveToDevicePos(cryptoPersisted: true, frame: "T9", last: "T5") == "T9")
    }

    /// (c) Carry-forward: a frame with no to-device section (`frame == nil`) keeps
    /// the last cursor, so every `sync_ack` re-sends the latest durable value.
    @Test func carriesForwardWhenFrameHasNoToDevice() {
        #expect(MatrixSession.resolveToDevicePos(cryptoPersisted: true, frame: nil, last: "T5") == "T5")
    }

    /// (e) Never advance past unsaved keys: if the crypto persist FAILED, keep the
    /// last good cursor even though the frame carried a new one — so the homeserver
    /// re-delivers this frame's to-device next sync (idempotent re-import) instead
    /// of deleting keys the device never saved.
    @Test func doesNotAdvanceWhenCryptoFailed() {
        #expect(MatrixSession.resolveToDevicePos(cryptoPersisted: false, frame: "T9", last: "T5") == "T5")
    }

    /// nil only until the very first durably-persisted to-device batch.
    @Test func nilUntilFirstBatch() {
        // No frame cursor, nothing acked yet → still nil.
        #expect(MatrixSession.resolveToDevicePos(cryptoPersisted: true, frame: nil, last: nil) == nil)
        // First real batch with saved keys → adopt it.
        #expect(MatrixSession.resolveToDevicePos(cryptoPersisted: true, frame: "T1", last: nil) == "T1")
        // First batch but keys NOT saved → still nil (don't advance past unsaved keys).
        #expect(MatrixSession.resolveToDevicePos(cryptoPersisted: false, frame: "T1", last: nil) == nil)
    }

    // MARK: - SEND: (b) `sync_ack` echoes the to-device cursor

    @Test func syncAckCarriesBothCursors() {
        let frame = GatewayClient.syncAckFrame(pos: "R4", toDevicePos: "T4")
        #expect(frame["t"] as? String == "sync_ack")
        #expect(frame["pos"] as? String == "R4")
        #expect(frame["to_device_pos"] as? String == "T4")
    }

    @Test func syncAckOmitsToDevicePosWhenNoneOnDurableStorage() {
        // Absent `to_device_pos` → the gateway leaves the to-device cursor
        // unchanged (used before the first to-device batch is ever persisted).
        let frame = GatewayClient.syncAckFrame(pos: "R5", toDevicePos: nil)
        #expect(frame["pos"] as? String == "R5")
        #expect(frame["to_device_pos"] == nil)
    }

    // MARK: - SEND: (d) `sync_start` resumes BOTH cursors on reconnect

    @Test func syncStartResumesBothCursorsOnReconnect() {
        // Warm reconnect: both last-durable cursors are resent so the gateway
        // seeds both upstream cursors from them.
        let frame = GatewayClient.syncStartFrame(body: ["lists": [:]], pos: "R6", toDevicePos: "T6")
        #expect(frame["t"] as? String == "sync_start")
        #expect(frame["pos"] as? String == "R6")
        #expect(frame["to_device_pos"] as? String == "T6")
    }

    @Test func roomCursorResumesWhenRoomSnapshotExists() {
        #expect(MatrixSession.roomCursorForStart(savedPos: "R6", restoredRoomCount: 3) == "R6")
    }

    @Test func roomCursorOmitsWithoutRoomSnapshot() {
        #expect(MatrixSession.roomCursorForStart(savedPos: "R6", restoredRoomCount: 0) == nil)
        #expect(MatrixSession.roomCursorForStart(savedPos: nil, restoredRoomCount: 3) == nil)
    }

    @Test func syncStartResumesToDeviceCursorEvenWhenRoomCursorIsOmitted() {
        // No room snapshot yet: omit the ROOM cursor once to recover room metadata,
        // but still resume the independent to-device cursor from durable storage.
        let frame = GatewayClient.syncStartFrame(body: ["lists": [:]], pos: nil, toDevicePos: "T6")
        #expect(frame["pos"] == nil)
        #expect(frame["to_device_pos"] as? String == "T6")
    }

    @Test func roomSnapshotCodecPreservesResumeSeed() throws {
        let snapshot = MatrixSession.StoredRoomSnapshot(
            roomOrder: ["!space:x", "!control:x", "!session:x"],
            roomMembers: [
                "!control:x": ["@me:x", "@plugin:x"],
                "!session:x": ["@me:x", "@plugin:x"]
            ],
            roomNames: ["!session:x": "Support"],
            spaceRooms: ["!space:x"],
            encryptedRooms: ["!control:x", "!session:x"],
            roomKinds: ["!control:x": "control", "!session:x": "session"],
            pinnedRoomIds: ["!session:x"],
            mutedRoomIds: ["!session:x"],
            activeRoomId: "!session:x"
        )
        let data = try #require(MatrixSession.encodeRoomSnapshot(snapshot))
        #expect(MatrixSession.decodeRoomSnapshot(data) == snapshot)
    }

    @MainActor
    @Test func roomSnapshotRecordStoresEncodedResumeSeed() throws {
        let container = try ModelContainer(
            for: MatrixRoomSnapshot.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let snapshot = MatrixSession.StoredRoomSnapshot(
            roomOrder: ["!control:x", "!session:x"],
            roomMembers: ["!session:x": ["@me:x", "@plugin:x"]],
            roomNames: ["!session:x": "Support"],
            spaceRooms: [],
            encryptedRooms: ["!session:x"],
            roomKinds: ["!control:x": "control", "!session:x": "session"],
            pinnedRoomIds: ["!session:x"],
            mutedRoomIds: [],
            activeRoomId: "!session:x"
        )
        let data = try #require(MatrixSession.encodeRoomSnapshot(snapshot))
        context.insert(MatrixRoomSnapshot(
            userId: "@me:x",
            schemaVersion: snapshot.schemaVersion,
            snapshotData: data
        ))
        try context.save()

        var descriptor = FetchDescriptor<MatrixRoomSnapshot>(
            predicate: #Predicate { $0.userId == "@me:x" }
        )
        descriptor.fetchLimit = 1
        let record = try #require(try context.fetch(descriptor).first)
        #expect(MatrixSession.decodeRoomSnapshot(record.snapshotData) == snapshot)
    }

    @Test func syncStartOmitsBothOnGenuinelyFreshSync() {
        // A brand-new sync with no durable cursor of either kind → omit both; the
        // gateway starts both cursors from scratch.
        let frame = GatewayClient.syncStartFrame(body: ["lists": [:]], pos: nil, toDevicePos: nil)
        #expect(frame["pos"] == nil)
        #expect(frame["to_device_pos"] == nil)
        #expect(frame["t"] as? String == "sync_start")
    }

    // MARK: - SEND: `ui_state` foreground report (protocol D.1 / D.4)

    @Test func uiStateFrameReportsForegroundTrue() {
        let frame = GatewayClient.uiStateFrame(foreground: true)
        #expect(frame["t"] as? String == "ui_state")
        #expect(frame["foreground"] as? Bool == true)
    }

    @Test func uiStateFrameReportsForegroundFalse() {
        let frame = GatewayClient.uiStateFrame(foreground: false)
        #expect(frame["t"] as? String == "ui_state")
        #expect(frame["foreground"] as? Bool == false)
    }

    // MARK: - sync_reset (protocol D.1/D.2 cursor-expiry recovery)

    /// READ: a `pos_expired` reset names `["pos"]` — decode exactly that.
    @Test func syncResetParsesNamedCursors() {
        let frame: [String: Any] = ["t": "sync_reset", "reason": "pos_expired", "cursors": ["pos"]]
        #expect(GatewayClient.syncResetCursors(from: frame) == ["pos"])
    }

    /// READ: a malformed/absent `cursors` field degrades to an empty list (discard
    /// nothing) — a bad reset must never crash the client, and clearing nothing is
    /// the safe direction (a stale `pos` just re-triggers M_UNKNOWN_POS next time).
    @Test func syncResetParsesEmptyWhenCursorsMissingOrMalformed() {
        #expect(GatewayClient.syncResetCursors(from: ["t": "sync_reset", "reason": "pos_expired"]) == [])
        #expect(GatewayClient.syncResetCursors(from: ["t": "sync_reset", "cursors": "pos"]) == [])
        // Non-string entries are dropped; valid ones kept.
        #expect(GatewayClient.syncResetCursors(from: ["cursors": ["pos", 7, "to_device_pos"]]) == ["pos", "to_device_pos"])
    }

    /// DECIDE: selective clearing — `pos_expired` clears the ROOM cursor only,
    /// leaving `to_device_pos` (and its Megolm keys) intact (D.2 "Device rule").
    @Test func posExpiredResetClearsRoomCursorOnly() {
        #expect(MatrixSession.durableCursorsToClear(named: ["pos"]) == ["pos"])
    }

    /// DECIDE: an explicitly-named to-device reset is honored; an unknown cursor
    /// name is ignored (forward-compatible); duplicates collapse, order preserved.
    @Test func durableCursorsToClearFiltersAndDedupes() {
        #expect(MatrixSession.durableCursorsToClear(named: ["pos", "to_device_pos"]) == ["pos", "to_device_pos"])
        #expect(MatrixSession.durableCursorsToClear(named: ["pos", "weird", "pos"]) == ["pos"])
        #expect(MatrixSession.durableCursorsToClear(named: []) == [])
        #expect(MatrixSession.durableCursorsToClear(named: ["unknown_only"]) == [])
    }

    @Test func authErrorExtractsUnsupportedVersionWindow() throws {
        let frame: [String: Any] = [
            "t": "auth_error",
            "reason": "unsupported_client_version",
            "min_client_version": "1.2.0",
            "max_client_version": NSNull(),
        ]
        let window = try #require(GatewayClient.unsupportedVersionWindow(from: frame))
        #expect(window.minClientVersion == "1.2.0")
        #expect(window.maxClientVersion == nil)
    }
}
