import Foundation
import Testing
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

    @Test func syncStartResumesToDeviceCursorEvenOnColdFullRoomSync() {
        // Cold launch: the ROOM cursor is omitted (pos == nil) to force a full room
        // snapshot, but the to-device cursor is INDEPENDENT — its keys survive in
        // the crypto store — so it is still resumed. Conflating the two (dropping
        // to_device_pos on cold launch) would re-deliver/redrop keys; keeping it
        // separate is the whole point.
        let frame = GatewayClient.syncStartFrame(body: ["lists": [:]], pos: nil, toDevicePos: "T6")
        #expect(frame["pos"] == nil)
        #expect(frame["to_device_pos"] as? String == "T6")
    }

    @Test func syncStartOmitsBothOnGenuinelyFreshSync() {
        // A brand-new sync with no durable cursor of either kind → omit both; the
        // gateway starts both cursors from scratch.
        let frame = GatewayClient.syncStartFrame(body: ["lists": [:]], pos: nil, toDevicePos: nil)
        #expect(frame["pos"] == nil)
        #expect(frame["to_device_pos"] == nil)
        #expect(frame["t"] as? String == "sync_start")
    }
}
