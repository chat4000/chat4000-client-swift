import Foundation

/// Persistent store of the highest relay-assigned `seq` (per protocol §6.4 +
/// §6.6) the client has stably persisted, scoped per group_id. Sent on every
/// `hello.last_acked_seq` to enable ack-driven offline-queue replay.
///
/// Storage is `UserDefaults` keyed by group_id. Writes are durable enough for
/// our purposes: they fsync on app suspend and on reconnect we tolerate
/// re-receiving a few duplicate seqs (we dedupe by inner msg_id at insert
/// time per §6.6.9).
@MainActor
enum AckSeqStore {
    private static let prefix = "chat4000.ackSeqStore.lastAckedSeq."

    /// Returns 0 if no ack has ever been recorded for this group.
    static func lastAckedSeq(forGroupId groupId: String) -> UInt64 {
        let key = prefix + groupId
        let raw = UserDefaults.standard.object(forKey: key) as? NSNumber
        return raw?.uint64Value ?? 0
    }

    /// Record a new high-water mark. Monotonic — never moves backwards.
    static func recordAcked(seq: UInt64, forGroupId groupId: String) {
        let key = prefix + groupId
        let current = lastAckedSeq(forGroupId: groupId)
        guard seq > current else { return }
        UserDefaults.standard.set(NSNumber(value: seq), forKey: key)
    }

    /// Wipe the high-water mark. Use after a fresh re-pair (the new group_id
    /// has its own counter; the old group_id's residue is harmless but stale).
    static func clear(forGroupId groupId: String) {
        let key = prefix + groupId
        UserDefaults.standard.removeObject(forKey: key)
    }
}
