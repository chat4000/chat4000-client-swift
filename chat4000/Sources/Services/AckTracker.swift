import Foundation

/// Debounced emitter for the protocol §6.6.3 `recv_ack` frame.
///
/// The relay assigns a per-recipient monotonic `seq` to every outbound
/// `msg.payload`. After we stably persist (or otherwise process) a received
/// inner message, we add its `seq` to this tracker. The tracker computes a
/// cumulative high-water mark plus optional selective ranges for out-of-order
/// arrivals, then emits a single `recv_ack` frame on the WebSocket whenever
/// any of these conditions becomes true (whichever first):
///
/// - 32 newly persisted seqs are pending acknowledgement
/// - 50 ms have elapsed since the most recent persistence
/// - the application is closing the WebSocket cleanly (final flush)
///
/// One tracker instance lives per `RelayClient`. State is reset on disconnect.
@MainActor
final class AckTracker {
    /// Sender callback. Implemented by RelayClient to ship the encoded
    /// `recv_ack` frame on the live WebSocket.
    var send: ((String) -> Void)?

    /// Persistent group_id used to checkpoint last_acked_seq across launches.
    var groupId: String?

    private var pending: Set<UInt64> = []
    private var debounceTask: Task<Void, Never>?
    private let batchThreshold = 32
    private let debounceMillis: UInt64 = 50

    /// Record a seq the client has just stably processed. Schedules a flush.
    func recordPersisted(_ seq: UInt64) {
        guard let groupId else { return }
        let lastAcked = AckSeqStore.lastAckedSeq(forGroupId: groupId)
        guard seq > lastAcked else { return } // already acked
        pending.insert(seq)

        if pending.count >= batchThreshold {
            flushNow()
        } else {
            scheduleDebounceFlush()
        }
    }

    /// Force an immediate flush. Called on backgrounding / disconnect to make
    /// sure any persisted seqs are durably acked before the socket closes.
    func flushNow() {
        debounceTask?.cancel()
        debounceTask = nil
        emit()
    }

    /// Reset the in-flight set. Called on connect (fresh start) so we never
    /// emit stale ranges from a previous session against a new socket.
    func reset() {
        debounceTask?.cancel()
        debounceTask = nil
        pending.removeAll()
    }

    private func scheduleDebounceFlush() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.debounceMillis ?? 50) * 1_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.emit() }
        }
    }

    private func emit() {
        guard !pending.isEmpty,
              let groupId,
              let send
        else { return }

        let lastAcked = AckSeqStore.lastAckedSeq(forGroupId: groupId)
        let sorted = pending.sorted()

        // Walk forward to find the new contiguous high-water mark above the
        // current persisted last_acked_seq. Anything above the contiguous run
        // becomes selective ranges.
        var newHWM = lastAcked
        var idx = 0
        for seq in sorted {
            if seq == newHWM + 1 {
                newHWM = seq
                idx += 1
            } else if seq <= newHWM {
                idx += 1 // already covered, drop quietly
            } else {
                break
            }
        }

        let leftover = Array(sorted[idx...])
        let ranges = compressToRanges(leftover)

        guard newHWM > lastAcked || !ranges.isEmpty else {
            // Nothing new to ack (everything pending was below the HWM or
            // the HWM didn't move; the relay knows about lower seqs already).
            pending.removeAll()
            return
        }

        guard let frame = RelayOutgoing.recvAck(
            upToSeq: newHWM,
            ranges: ranges.isEmpty ? nil : ranges
        ) else {
            return
        }

        AppLog.log(
            "📤 recv_ack up_to_seq=%llu ranges=%d (pending=%d)",
            newHWM,
            ranges.count,
            pending.count
        )
        send(frame)

        // Persist the new high-water mark and clear pending. Selective ranges
        // remain pending until they merge with a future contiguous run.
        if newHWM > lastAcked {
            AckSeqStore.recordAcked(seq: newHWM, forGroupId: groupId)
        }
        pending = Set(leftover)
    }

    /// Collapse a sorted array of seqs into `[low, high]` inclusive pairs.
    /// Bounded at 32 ranges per protocol §6.6.3.
    private func compressToRanges(_ sorted: [UInt64]) -> [[UInt64]] {
        guard !sorted.isEmpty else { return [] }
        var result: [[UInt64]] = []
        var low = sorted[0]
        var high = sorted[0]
        for seq in sorted.dropFirst() {
            if seq == high + 1 {
                high = seq
            } else {
                result.append([low, high])
                if result.count >= 32 { return result }
                low = seq
                high = seq
            }
        }
        result.append([low, high])
        return result
    }
}
