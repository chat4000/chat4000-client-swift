import Foundation
import MatrixRustSDK

/// v2 `MessageTransport` backed by `MatrixSession`. Same façade as the v1
/// `RelayMessageTransport`, so `ChatViewModel` and the UI are unchanged.
///
/// `MatrixSession` owns the room list + the active room; this transport just
/// **binds the active room's `Timeline`** and translates its diffs into the
/// app's internal `InnerMessage` DTO (history → finalized text; live agent edits
/// → the `textDelta`/`textEnd` streaming frames ChatViewModel already handles;
/// our own messages tagged `role == .app` so self-echo suppression drops them).
///
/// NOTE (multi-room): `ChatViewModel`/`ChatMessage` are not yet room-scoped, so
/// switching rooms re-emits the new room's timeline into the same message list.
/// Per-room scoping (a `roomId` on `ChatMessage`) is the next step.
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

    @ObservationIgnored private var timeline: Timeline?
    @ObservationIgnored private var timelineHandle: TaskHandle?
    @ObservationIgnored private var boundRoomId: String?

    // Timeline → InnerMessage state (reset on every room rebind). The decision
    // logic lives in the pure, unit-tested `MatrixTimelineMapper`.
    @ObservationIgnored private var mapper = MatrixTimelineMapper()
    @ObservationIgnored private var initialLoaded = false
    @ObservationIgnored private var finalizeTask: Task<Void, Never>?

    init(session: MatrixSession = MatrixSession()) {
        self.session = session
        session.onConnectionStateChange = { [weak self] state in
            self?.onConnectionState?(state)
        }
        session.onActiveRoomChange = { [weak self] roomId in
            guard let roomId else { return }
            Task { @MainActor in await self?.bindTimeline(roomId) }
        }
    }

    // MARK: - MessageTransport

    func connect() {
        Task { await session.connect() }
    }

    func disconnect() {
        finalizeTask?.cancel()
        timelineHandle?.cancel()
        timelineHandle = nil
        timeline = nil
        boundRoomId = nil
        resetTimelineState()
        Task { await session.disconnect() }
    }

    @discardableResult
    func send(_ msg: OutboundMessage) -> String {
        let localId = UUID().uuidString
        switch msg {
        case .text(let text):
            guard let timeline else {
                AppLog.log("⚠️ Matrix send dropped — no bound room yet")
                return localId
            }
            let content = messageEventContentFromMarkdown(md: text)
            Task { _ = try? await timeline.send(msg: content) }

        case .image, .audio:
            // TODO(v2): Matrix media upload.
            AppLog.log("⚠️ Matrix media send not implemented yet")

        case .textDelta, .textEnd, .status, .ack:
            break // inbound-only in v2
        }
        return localId
    }

    // MARK: - Timeline binding (follows MatrixSession.activeRoomId)

    private func bindTimeline(_ roomId: String) async {
        guard boundRoomId != roomId, let rls = session.roomListService else { return }
        // Tear down the previous room's listener + per-room mapping state.
        finalizeTask?.cancel()
        timelineHandle?.cancel()
        timelineHandle = nil
        timeline = nil
        resetTimelineState()

        do {
            let room = try rls.room(roomId: roomId)
            let timeline = try await room.timeline()
            self.timeline = timeline
            self.boundRoomId = roomId
            let observer = TimelineObserver { [weak self] diffs in
                Task { @MainActor in self?.handleDiffs(diffs) }
            }
            self.timelineHandle = await timeline.addListener(listener: observer)
            AppLog.log("✅ Matrix bound to room \(roomId)")
        } catch {
            AppLog.log("❌ Matrix timeline bind failed for \(roomId): \(error)")
        }
    }

    // MARK: - Timeline diff → InnerMessage (decisions in MatrixTimelineMapper)

    private func handleDiffs(_ diffs: [TimelineDiff]) {
        for diff in diffs {
            switch diff {
            case .append(let values): values.forEach { feed($0, live: initialLoaded) }
            case .reset(let values): values.forEach { feed($0, live: false) }
            case .pushFront(let value): feed(value, live: false)
            case .pushBack(let value): feed(value, live: true)
            case .insert(_, let value): feed(value, live: true)
            case .set(_, let value): feed(value, live: true)
            case .clear: mapper.reset()
            case .popFront, .popBack, .remove, .truncate: break
            }
        }
        initialLoaded = true
    }

    private func feed(_ item: TimelineItem, live: Bool) {
        guard let event = item.asEvent() else { return }
        guard case let .eventId(eid) = event.eventOrTransactionId else { return }
        guard let body = Self.textBody(of: event.content), !body.isEmpty else { return }

        let tsMs = Int64(event.timestamp)
        let emits = mapper.ingest(
            eventId: eid, body: body, senderId: event.sender, isOwn: event.isOwn, live: live
        )
        for emit in emits { applyEmit(emit, ts: tsMs) }
        if mapper.activeStreamId != nil { scheduleFinalize(ts: tsMs) }
    }

    /// Matrix has no explicit "stream finished" beyond the MSC4357 live marker,
    /// so settle the active stream after a quiet period.
    private func scheduleFinalize(ts: Int64) {
        finalizeTask?.cancel()
        finalizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled else { return }
            if let emit = self.mapper.finalizeActiveStream() { self.applyEmit(emit, ts: ts) }
        }
    }

    private func resetTimelineState() {
        mapper.reset()
        initialLoaded = false
        finalizeTask?.cancel()
        finalizeTask = nil
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

    /// Plain-text body from a timeline item's content, if text-like; else nil.
    private static func textBody(of content: TimelineItemContent) -> String? {
        guard case let .msgLike(msgLike) = content else { return nil }
        guard case let .message(message) = msgLike.kind else { return nil }
        switch message.msgType {
        case .text(let c): return c.body
        case .notice(let c): return c.body
        case .emote(let c): return c.body
        default: return message.body
        }
    }
}

private final class TimelineObserver: TimelineListener, @unchecked Sendable {
    private let handler: @Sendable ([TimelineDiff]) -> Void
    init(_ handler: @escaping @Sendable ([TimelineDiff]) -> Void) { self.handler = handler }
    func onUpdate(diff: [TimelineDiff]) { handler(diff) }
}
