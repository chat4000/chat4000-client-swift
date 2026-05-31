import Foundation

/// v2 `MessageTransport` backed by `MatrixSession` (gateway + standalone
/// crypto). Same façade as before, so `ChatViewModel` and the UI are unchanged.
///
/// `MatrixSession` owns sync + decryption and hands this transport the active
/// room's decrypted events (`onRoomEvent`) and status (`onActiveRoomStatus`).
/// This type maps them onto the app's internal `InnerMessage` DTO using the
/// finalized protocol turn model (protocol E):
///   • a turn is one anchor message edited via `m.replace`; we collapse the
///     anchor + its edits onto one stream id and let the pure
///     `MatrixTimelineMapper` emit `textDelta`/`textEnd` (streaming feel);
///   • `chat4000.tool` events (+ their `m.replace` completion edit) → the
///     `toolStart`/`toolEnd` bubbles ChatViewModel already renders;
///   • the cleartext `chat4000.status` state → a `status` inner message.
/// `m.relates_to` and the body live where protocol E puts them: the relation on
/// the cleartext envelope (the `outer` event), the text inside the decrypted
/// content (`m.new_content.body` for an edit).
@MainActor
@Observable
final class MatrixMessageTransport: MessageTransport {
    let session: MatrixSession

    var onReceive: ((InnerMessage) -> Void)?
    var onStatus: ((MessageStatusUpdate) -> Void)?
    var onConnectionState: ((ConnectionState) -> Void)?
    var onTermsVersionUpdate: ((Int) -> Void)?

    var state: ConnectionState { session.connectionState }
    var currentGroupId: String? { session.userId }

    // Per-room mapping state (reset on every room switch).
    @ObservationIgnored private var mapper = MatrixTimelineMapper()
    @ObservationIgnored private var finalizeTask: Task<Void, Never>?
    @ObservationIgnored private var emittedToolStarts: Set<String> = []
    @ObservationIgnored private var emittedToolEnds: Set<String> = []
    /// Newest event id seen in the active room (for read receipts).
    @ObservationIgnored private var lastEventId: String?

    init(session: MatrixSession = MatrixSession()) {
        self.session = session
        session.onConnectionStateChange = { [weak self] state in
            self?.onConnectionState?(state)
        }
        session.onActiveRoomChange = { [weak self] _ in
            self?.resetMappingState()
        }
        session.onRoomEvent = { [weak self] _, event, live in
            self?.ingest(event, live: live)
        }
        session.onActiveRoomStatus = { [weak self] state in
            self?.emitStatus(state)
        }
    }

    // MARK: - MessageTransport

    func connect() {
        Task { await session.connect() }
    }

    func disconnect() {
        finalizeTask?.cancel()
        resetMappingState()
        Task { await session.disconnect() }
    }

    @discardableResult
    func send(_ msg: OutboundMessage) -> String {
        let localId = UUID().uuidString
        switch msg {
        case .text(let text):
            guard let roomId = session.activeRoomId else {
                AppLog.log("⚠️ Matrix send dropped — no active room yet")
                return localId
            }
            Task { await session.sendText(text, roomId: roomId) }
        case .image, .audio:
            // TODO(v2): authenticated media over HTTP (protocol D.3) — encrypt
            // blob, upload to the gateway media path, send m.image/m.audio.
            AppLog.log("⚠️ Matrix media send not implemented yet")
        case .textDelta, .textEnd, .status, .ack:
            break // inbound-only in v2
        }
        return localId
    }

    func markRead() {
        guard let roomId = session.activeRoomId, let eventId = lastEventId else { return }
        Task { await session.sendReadReceipt(roomId: roomId, eventId: eventId) }
    }

    // MARK: - Event → InnerMessage mapping

    private func ingest(_ event: DecryptedRoomEvent, live: Bool) {
        if let eid = event.outer.eventId { lastEventId = eid }
        guard let clear = event.clear, let clearObj = json(clear) else { return }
        let content = clearObj["content"] as? [String: Any] ?? [:]
        let ts = event.outer.originServerTs ?? 0
        let relation = relatesTo(event.outer)

        switch content["msgtype"] as? String {
        case "m.text", "m.notice", "m.emote":
            handleText(content: content, relation: relation, outer: event.outer, isOwn: event.isOwn, live: live, ts: ts)
        case "chat4000.tool":
            handleTool(content: content, sender: event.outer.sender, ts: ts)
        default:
            break
        }
    }

    private func handleText(
        content: [String: Any],
        relation: (relType: String, eventId: String)?,
        outer: SyncEvent,
        isOwn: Bool,
        live: Bool,
        ts: Int64
    ) {
        let isEdit = relation?.relType == "m.replace"
        let body: String
        if isEdit, let newContent = content["m.new_content"] as? [String: Any],
           let edited = newContent["body"] as? String {
            body = edited
        } else {
            body = content["body"] as? String ?? ""
        }
        guard !body.isEmpty else { return }

        // Collapse the anchor + its m.replace edits onto one stream id (the
        // anchor's event id) so the mapper sees a single growing message.
        let streamKey = (isEdit ? relation?.eventId : outer.eventId) ?? outer.eventId ?? UUID().uuidString
        let emits = mapper.ingest(eventId: streamKey, body: body, senderId: outer.sender ?? "", isOwn: isOwn, live: live)
        for emit in emits { applyEmit(emit, ts: ts) }
        if mapper.activeStreamId != nil { scheduleFinalize(ts: ts) }
    }

    private func handleTool(content: [String: Any], sender: String?, ts: Int64) {
        // The completion arrives as an m.replace edit carrying the updated tool
        // object under `m.new_content`; prefer that, fall back to the direct one.
        let toolObj = (content["m.new_content"] as? [String: Any])?["chat4000.tool"] as? [String: Any]
            ?? content["chat4000.tool"] as? [String: Any]
        guard let tool = toolObj else { return }

        let toolId = tool["tool_id"] as? String ?? UUID().uuidString
        let from = MatrixTimelineMapper.sender(matrixUserId: sender ?? "", isOwn: false)

        if emittedToolStarts.insert(toolId).inserted {
            onReceive?(InnerMessage(
                t: .toolStart, id: UUID().uuidString, from: from,
                body: .toolStart(.init(
                    toolId: toolId,
                    name: tool["name"] as? String ?? "tool",
                    args: tool["args"] as? String ?? "",
                    icon: tool["icon"] as? String)), ts: ts))
        }

        let status = tool["status"] as? String ?? "running"
        if status != "running", emittedToolEnds.insert(toolId).inserted {
            onReceive?(InnerMessage(
                t: .toolEnd, id: UUID().uuidString, from: from,
                body: .toolEnd(.init(
                    toolId: toolId,
                    status: status == "failed" ? .failed : .done,
                    result: tool["result"] as? String ?? "",
                    durationMs: intValue(tool["duration_ms"]) ?? 0)), ts: ts))
        }
    }

    /// Map a `chat4000.status` state value to a status inner message. The
    /// protocol's `working` collapses to the app's "thinking" busy phase.
    private func emitStatus(_ state: String) {
        let mapped = (state == "working") ? "thinking" : state
        onReceive?(InnerMessage(
            t: .status, id: UUID().uuidString,
            from: SenderInfo(role: .plugin, deviceId: "", deviceName: ""),
            body: .status(.init(status: mapped)), ts: 0))
    }

    private func applyEmit(_ emit: MatrixTimelineMapper.Emit, ts: Int64) {
        switch emit {
        case let .text(id, body, senderId, isOwn):
            onReceive?(InnerMessage(
                t: .text, id: id,
                from: MatrixTimelineMapper.sender(matrixUserId: senderId, isOwn: isOwn),
                body: .text(.init(text: body)), ts: ts))
        case let .delta(streamId, delta, senderId):
            onReceive?(InnerMessage(
                t: .textDelta, id: UUID().uuidString,
                from: MatrixTimelineMapper.sender(matrixUserId: senderId, isOwn: false),
                body: .textDelta(.init(delta: delta, streamId: streamId)), ts: ts))
        case let .end(streamId, body, senderId):
            onReceive?(InnerMessage(
                t: .textEnd, id: UUID().uuidString,
                from: MatrixTimelineMapper.sender(matrixUserId: senderId, isOwn: false),
                body: .textEnd(.init(text: body, reset: nil, streamId: streamId)), ts: ts))
        }
    }

    /// Matrix has no explicit "stream finished" signal beyond the final edit, so
    /// settle the active stream after a quiet period.
    private func scheduleFinalize(ts: Int64) {
        finalizeTask?.cancel()
        finalizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled else { return }
            if let emit = self.mapper.finalizeActiveStream() { self.applyEmit(emit, ts: ts) }
        }
    }

    private func resetMappingState() {
        mapper.reset()
        emittedToolStarts.removeAll()
        emittedToolEnds.removeAll()
        lastEventId = nil
        finalizeTask?.cancel()
        finalizeTask = nil
    }

    // MARK: - JSON helpers

    private func json(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Read `m.relates_to` from the cleartext envelope (the outer event).
    private func relatesTo(_ outer: SyncEvent) -> (relType: String, eventId: String)? {
        guard let obj = json(outer.rawJSON),
              let content = obj["content"] as? [String: Any],
              let relates = content["m.relates_to"] as? [String: Any],
              let relType = relates["rel_type"] as? String,
              let eventId = relates["event_id"] as? String
        else { return nil }
        return (relType, eventId)
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        case let d as Double: return Int(d)
        default: return nil
        }
    }
}
