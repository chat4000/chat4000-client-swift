import Foundation

/// Pure, testable core of the Matrix timeline → `InnerMessage` mapping.
///
/// `MatrixMessageTransport` extracts primitives from SDK timeline items
/// (`eventId`, `body`, `senderId`, `isOwn`, `live`) and feeds them here; this
/// type decides what to emit (finalized text vs streaming delta/end) and the
/// transport converts the decisions into `InnerMessage`s. Keeping the decision
/// logic free of SDK types makes the tricky streaming behaviour unit-testable.
struct MatrixTimelineMapper {
    enum Emit: Equatable {
        /// A complete (non-streaming) message — history or our own echo.
        case text(id: String, body: String, senderId: String, isOwn: Bool)
        /// A streaming increment (only the newly-appended suffix).
        case delta(streamId: String, delta: String, senderId: String)
        /// A streaming message settled with its full text.
        case end(streamId: String, body: String, senderId: String)
    }

    private var seen: Set<String> = []
    private var bodyByEvent: [String: String] = [:]
    private(set) var activeStreamId: String?
    private var activeStreamSenderId: String?

    /// Ingest one timeline event. `live` distinguishes the initial history
    /// backfill (false → finalized text) from events arriving after load
    /// (true → an agent message streams via deltas).
    mutating func ingest(eventId: String, body: String, senderId: String, isOwn: Bool, live: Bool) -> [Emit] {
        var out: [Emit] = []

        if !seen.contains(eventId) {
            seen.insert(eventId)
            bodyByEvent[eventId] = body
            if live && !isOwn {
                // Settle any previous stream before starting a new one.
                if let prev = activeStreamId, prev != eventId {
                    out.append(.end(streamId: prev, body: bodyByEvent[prev] ?? "", senderId: activeStreamSenderId ?? senderId))
                }
                activeStreamId = eventId
                activeStreamSenderId = senderId
                out.append(.delta(streamId: eventId, delta: body, senderId: senderId))
            } else {
                out.append(.text(id: eventId, body: body, senderId: senderId, isOwn: isOwn))
            }
        } else {
            let old = bodyByEvent[eventId] ?? ""
            guard body != old else { return [] }
            bodyByEvent[eventId] = body
            if activeStreamId == eventId, body.hasPrefix(old) {
                out.append(.delta(streamId: eventId, delta: String(body.dropFirst(old.count)), senderId: senderId))
            } else if activeStreamId == eventId {
                // Non-prefix edit (correction) — settle with the full text.
                out.append(.end(streamId: eventId, body: body, senderId: senderId))
                activeStreamId = nil
                activeStreamSenderId = nil
            }
        }
        return out
    }

    /// Settle the active stream (called on the transport's quiet-period debounce).
    mutating func finalizeActiveStream() -> Emit? {
        guard let eid = activeStreamId else { return nil }
        let emit = Emit.end(streamId: eid, body: bodyByEvent[eid] ?? "", senderId: activeStreamSenderId ?? eid)
        activeStreamId = nil
        activeStreamSenderId = nil
        return emit
    }

    /// Drop all per-room state (on room switch or timeline clear).
    mutating func reset() {
        seen.removeAll()
        bodyByEvent.removeAll()
        activeStreamId = nil
        activeStreamSenderId = nil
    }

    /// Sender tagging: our own events → `.app` + this device's id (so
    /// ChatViewModel's self-echo suppression drops them); others → `.plugin`.
    static func sender(matrixUserId: String, isOwn: Bool) -> SenderInfo {
        if isOwn {
            return SenderInfo(role: .app, deviceId: DeviceIdentity.currentDeviceId, deviceName: "")
        }
        return SenderInfo(role: .plugin, deviceId: matrixUserId, deviceName: matrixUserId)
    }
}
