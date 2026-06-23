import Foundation
import SwiftData
import SwiftUI

/// One always-mounted view model per Matrix room (session). It owns THAT room's
/// messages, its own streaming/tool mapping pipeline, its own busy/status clock,
/// and persists every row with its OWN fixed `roomId` — never a shared mutable
/// `activeRoomId`. Because the `roomId` is immutable for the lifetime of the
/// instance, the active-room race that used to file one room's tool chips into
/// another room's timeline (the "tool-bleed") cannot happen here.
///
/// A background room keeps cooking + saving its widgets live (the active gate is
/// gone in `MatrixSession`), so its mounted-but-hidden view is already correct
/// the instant you bring it to front — no replay, no re-cook, no teardown.
@MainActor
@Observable
final class RoomViewModel {
    let roomId: String

    // Rendered state (observed by the room's view).
    var messages: [ChatMessage] = []
    var isAgentBusy = false
    var busyStartTime: Date?
    var busyPhase: String = "Thinking"
    var scrollRevision = 0
    /// Bumped ONLY when the local user sends a message (text/image/audio). Unlike
    /// `scrollRevision` (pin-gated "scroll if already at the bottom"), this forces
    /// an unconditional animated scroll to the bottom — same effect as tapping the
    /// scroll-to-bottom button — because sending always means "take me to my message".
    var sendScrollRevision = 0

    @ObservationIgnored private let session: MatrixSession
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var didLoadHistory = false

    // Streaming assembly (one in-flight agent stream at a time).
    @ObservationIgnored private var currentStreamId: String?
    @ObservationIgnored private var currentStreamText = ""
    @ObservationIgnored private var currentStreamMessageId: UUID?

    // Per-room event → InnerMessage mapping pipeline (was the single shared
    // transport's state; now owned per room so two rooms never share a mapper).
    @ObservationIgnored private var mapper = MatrixTimelineMapper()
    @ObservationIgnored private var emittedToolStarts: Set<String> = []
    /// Newest event id seen in this room (for the read receipt).
    @ObservationIgnored private var lastEventId: String?

    /// Latest applied `chat4000.status` origin_server_ts — the gate that makes the
    /// label a pure function of the NEWEST status (protocol E). Older/redelivered
    /// status (ts ≤ this) is ignored: no label change, no TTL re-arm.
    @ObservationIgnored private var latestStatusTs: Int64 = 0
    /// Protocol E stuck-spinner guard: if no fresh status arrives within 10s, the
    /// label self-clears. Reset on every status, cancelled on `idle`.
    @ObservationIgnored private var busyTTLTask: Task<Void, Never>?

    init(roomId: String, session: MatrixSession) {
        self.roomId = roomId
        self.session = session
    }

    // MARK: - Lifecycle

    /// Bind persistence and load this room's history once (scoped to `roomId`).
    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
        guard !didLoadHistory else { return }
        didLoadHistory = true
        loadHistory()
    }

    /// Re-fetch this room's stored rows, merging any in-memory-only transient rows
    /// (e.g. a just-sent `.sending` row). All rows are this room's (`roomId` is
    /// fixed), so there is no cross-room merge to leak another session's messages.
    func reloadHistory() {
        guard modelContext != nil else { return }
        loadHistory()
    }

    private func loadHistory() {
        guard let modelContext else { return }
        let rid = roomId
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.roomId == rid },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let fetched = (try? modelContext.fetch(descriptor)) ?? []
        let stored = deduplicatedStoredMessages(fetched, modelContext: modelContext)
        let storedIds = Set(stored.map(\.id))
        var merged = stored
        for message in messages where !storedIds.contains(message.id) {
            guard isUniqueStoredMessage(message, against: merged) else {
                AppLog.log(
                    "🧵 not re-inserting duplicate in-memory message room=%@ msg_id=%@",
                    roomId,
                    message.msgId ?? "nil"
                )
                continue
            }
            modelContext.insert(message)
            merged.append(message)
        }
        merged.sort { $0.timestamp < $1.timestamp }
        persistContext()
        messages = merged
        reenqueuePendingSends()
        requestScrollToBottom()
    }

    /// Re-queue any `.sending` user rows — a send that never completed (offline, or
    /// the app was killed mid-send) — so the outbox flushes them once we're
    /// connected. Safe to call on every load: the session dedups by local id, and a
    /// row that already went out is `.sent`/`.delivered`, never `.sending`.
    private func reenqueuePendingSends() {
        for row in messages where row.sender == .user && row.status == .sending {
            guard let localId = row.msgId, let content = outboxContent(for: row) else { continue }
            session.enqueueSend(content, roomId: roomId, localId: localId)
        }
    }

    private func outboxContent(for row: ChatMessage) -> MatrixSession.OutboxContent? {
        if let imageData = row.imageData {
            // Stored rows don't keep the original image mime; clawConnect always
            // sends JPEG, so default to that for a resumed image send.
            return .image(imageData, mimeType: "image/jpeg")
        }
        if let audioData = row.audioData {
            let durationMs = Int(((row.audioDuration ?? 0) * 1000).rounded())
            return .audio(audioData, mimeType: row.audioMimeType ?? VoiceNoteConstants.mimeType, durationMs: durationMs)
        }
        return row.text.isEmpty ? nil : .text(row.text)
    }

    private func deduplicatedStoredMessages(_ stored: [ChatMessage], modelContext: ModelContext) -> [ChatMessage] {
        var seenMsgIds: Set<String> = []
        var out: [ChatMessage] = []
        for message in stored {
            if Self.isToolTranscriptMessage(message) {
                AppLog.log(
                    "🧰 deleting stored tool transcript text room=%@ msg_id=%@",
                    roomId,
                    message.msgId ?? "nil"
                )
                modelContext.delete(message)
                continue
            }
            guard let msgId = message.msgId, !msgId.isEmpty else {
                out.append(message)
                continue
            }
            if seenMsgIds.insert(msgId).inserted {
                out.append(message)
            } else {
                AppLog.log("🧵 deleting duplicate stored message room=%@ msg_id=%@", roomId, msgId)
                modelContext.delete(message)
            }
        }
        return out
    }

    private static func isToolTranscriptMessage(_ message: ChatMessage) -> Bool {
        message.kind == .message && isPureToolTranscript(message.text)
    }

    static func isPureToolTranscript(_ text: String) -> Bool {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy(isToolTranscriptLine(_:))
    }

    private static func isToolTranscriptLine(_ line: String) -> Bool {
        let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2 else { return false }

        let rest = String(parts[1])
        guard let nameEnd = rest.firstIndex(where: isToolNameTerminator(_:)) else {
            return false
        }

        let name = String(rest[..<nameEnd])
        guard isLikelyToolName(name) else { return false }

        let suffix = String(rest[nameEnd...])
        return suffix.hasPrefix(":") || suffix.hasPrefix("...")
    }

    private static func isToolNameTerminator(_ character: Character) -> Bool {
        character == ":" || character == "." || character.isWhitespace
    }

    private static func isLikelyToolName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let knownSimpleNames: Set<String> = ["bash", "python", "terminal", "todo", "cronjob"]
        if knownSimpleNames.contains(name) { return true }
        return name.contains("_") || name.contains(".") || name.contains("-")
    }

    private func persistContext() {
        guard let modelContext else { return }
        do {
            try modelContext.save()
        } catch {
            ErrorReporter.capture(error, context: "RoomViewModel.persistContext")
        }
    }

    /// Convert a Matrix `origin_server_ts` (ms since epoch) to the row timestamp.
    /// Falls back to `.now` for own/local rows or a missing ts. This is what makes
    /// the timeline chronological: every inbound row is stamped with the EVENT's
    /// wall-clock time, not the moment we happened to ingest it.
    private func eventDate(_ ts: Int64) -> Date {
        ts > 0 ? Date(timeIntervalSince1970: Double(ts) / 1000) : .now
    }

    /// Insert keeping the timeline sorted by event timestamp. Protocol §6.4.2:
    /// "ordering of message rendering follows wall-clock `ts`" — NOT socket
    /// delivery order. A live catch-up sync (reconnect) delivers a room's backlog
    /// out of order, so a plain `append` produced a scrambled timeline (the weather
    /// card landing above its question, etc.). Stable for equal timestamps: a row
    /// delivered later with an equal ts sorts AFTER the earlier one.
    private func insertInTimestampOrder(_ message: ChatMessage) {
        if let idx = messages.firstIndex(where: { $0.timestamp > message.timestamp }) {
            messages.insert(message, at: idx)
        } else {
            messages.append(message)
        }
    }

    @discardableResult
    private func appendAndInsertUnique(_ message: ChatMessage, reason: String) -> Bool {
        guard let msgId = message.msgId, !msgId.isEmpty else {
            insertInTimestampOrder(message)
            modelContext?.insert(message)
            return true
        }
        if messages.contains(where: { $0.id != message.id && $0.msgId == msgId }) {
            AppLog.log(
                "🧵 blocked duplicate in-memory message room=%@ msg_id=%@ reason=%@",
                roomId,
                msgId,
                reason
            )
            return false
        }
        if storedMessageExists(msgId: msgId) {
            AppLog.log(
                "🧵 blocked duplicate stored message room=%@ msg_id=%@ reason=%@",
                roomId,
                msgId,
                reason
            )
            return false
        }
        insertInTimestampOrder(message)
        modelContext?.insert(message)
        return true
    }

    private func isUniqueStoredMessage(_ message: ChatMessage, against existing: [ChatMessage]) -> Bool {
        guard let msgId = message.msgId, !msgId.isEmpty else { return true }
        return !existing.contains { $0.msgId == msgId }
    }

    private func storedMessageExists(msgId: String) -> Bool {
        guard let modelContext else { return false }
        let rid = roomId
        var descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.msgId == msgId && $0.roomId == rid }
        )
        descriptor.fetchLimit = 1
        do {
            let existing = try modelContext.fetch(descriptor)
            return !existing.isEmpty
        } catch {
            ErrorReporter.capture(error, context: "RoomViewModel.storedMessageExists")
            AppLog.log(
                "🧵 duplicate check failed closed room=%@ msg_id=%@: %@",
                roomId,
                msgId,
                String(describing: error)
            )
            return true
        }
    }

    /// True if a row for this Matrix `eventId` is already persisted in this room
    /// (survives relaunch). Used to suppress the synced echo of our own send once
    /// its local row has been reconciled to the homeserver event_id.
    private func storedMessageExists(matrixEventId eventId: String) -> Bool {
        guard let modelContext else { return false }
        let rid = roomId
        var descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.matrixEventId == eventId && $0.roomId == rid }
        )
        descriptor.fetchLimit = 1
        do {
            return try !modelContext.fetch(descriptor).isEmpty
        } catch {
            ErrorReporter.capture(error, context: "RoomViewModel.storedMessageExists.eventId")
            AppLog.log("🧵 own-echo check failed closed room=%@ event_id=%@: %@",
                       roomId, eventId, String(describing: error))
            return true
        }
    }

    private func requestScrollToBottom() {
        scrollRevision &+= 1
    }

    /// Force an unconditional scroll to the bottom (the local user just sent a
    /// message). See `sendScrollRevision`.
    private func forceScrollToBottom() {
        sendScrollRevision &+= 1
    }

    // MARK: - Inbound event ingest (this room only)

    /// Map one decrypted room event onto the timeline. No active-room check is
    /// needed: this instance only ever receives its own room's events, and every
    /// row it persists is stamped with the fixed `roomId`.
    func ingest(_ event: DecryptedRoomEvent, live: Bool) {
        if let eid = event.outer.eventId { lastEventId = eid }
        guard let clear = event.clear, let clearObj = json(clear) else {
            handleUndecryptableEvent(event, live: live)
            return
        }
        let content = clearObj["content"] as? [String: Any] ?? [:]
        let ts = event.outer.originServerTs ?? 0
        let relation = relatesTo(event.outer)
        AppLog.debug("📥 ingest room=%@ type=%@ msgtype=%@ own=%@ live=%@",
                     roomId, clearObj["type"] as? String ?? "nil",
                     content["msgtype"] as? String ?? "nil", String(event.isOwn), String(live))

        if clearObj["type"] as? String == "chat4000.status" {
            handleStatus(content: content, ts: ts)
            return
        }

        if clearObj["type"] as? String == "chat4000.html_card" {
            handleHTMLCard(
                content: content,
                sender: event.outer.sender,
                isOwn: event.isOwn,
                eventId: event.outer.eventId,
                ts: ts
            )
            return
        }

        switch content["msgtype"] as? String {
        case "m.text", "m.notice", "m.emote":
            handleText(content: content, relation: relation, outer: event.outer, isOwn: event.isOwn, live: live, ts: ts)
        case "chat4000.tool":
            handleTool(content: content, sender: event.outer.sender, ts: ts)
        case "m.image":
            handleMedia(content: content, outer: event.outer, isOwn: event.isOwn, kind: .image, ts: ts)
        case "m.audio":
            handleMedia(content: content, outer: event.outer, isOwn: event.isOwn, kind: .audio, ts: ts)
        default:
            AppLog.log("🗑️ ingest DROPPED room=%@ type=%@ msgtype=%@ own=%@ clear=%@",
                       roomId, clearObj["type"] as? String ?? "nil",
                       content["msgtype"] as? String ?? "nil", String(event.isOwn), clear)
        }
    }

    private func handleHTMLCard(content: [String: Any], sender: String?, isOwn: Bool, eventId: String?, ts: Int64) {
        guard let html = content["html"] as? String else { return }
        AppLog.log("🃏 html card payload room=%@ event_id=%@ len=%d html=%@",
                   roomId, eventId ?? "nil", html.count, html)
        let from = MatrixTimelineMapper.sender(matrixUserId: sender ?? "", isOwn: isOwn)
        let messageSender: MessageSender = from.role == .app ? .user : .agent
        receiveHTMLCard(html, id: eventId ?? UUID().uuidString, sender: messageSender, ts: ts)
    }

    private func handleUndecryptableEvent(_ event: DecryptedRoomEvent, live: Bool) {
        guard event.outer.type == "m.room.encrypted" else {
            AppLog.debug("📥 ingest skip (no cleartext) room=%@ outerType=%@ eid=%@",
                         roomId, event.outer.type, event.outer.eventId ?? "nil")
            return
        }
        guard cleartextPushFlag(event.outer) != false else {
            AppLog.debug("📥 ingest skip (no key, non-push) room=%@ eid=%@",
                         roomId, event.outer.eventId ?? "nil")
            return
        }
        let id = event.outer.eventId ?? UUID().uuidString
        let from = MatrixTimelineMapper.sender(matrixUserId: event.outer.sender ?? "", isOwn: event.isOwn)
        let sender: MessageSender = from.role == .app ? .user : .agent
        AppLog.log("🔒 showing unavailable encrypted message room=%@ eid=%@ live=%@",
                   roomId, id, String(live))
        receiveUnavailable(id: id, sender: sender, ts: event.outer.originServerTs ?? 0)
    }

    private enum MediaKind { case image, audio }

    private func handleMedia(content: [String: Any], outer: SyncEvent, isOwn: Bool, kind: MediaKind, ts: Int64) {
        guard let file = content["file"] as? [String: Any] else { return }
        let id = outer.eventId ?? UUID().uuidString
        // Own media must render here too: Mac + iPhone are the SAME Matrix account on
        // two devices (isOwn is account-level), so a photo/voice note sent from one
        // device arrives on the other as own — dropping it (the old `guard !isOwn`)
        // is exactly why your own pictures never appeared on your other device. Only
        // skip the echo of THIS device's own send, which is already on screen via
        // local echo and carries this event_id once the send reconciled.
        if isOwn, messages.contains(where: { $0.matrixEventId == id }) || storedMessageExists(matrixEventId: id) {
            return
        }
        let info = content["info"] as? [String: Any] ?? [:]
        let mimeType = info["mimetype"] as? String ?? (kind == .image ? "image/jpeg" : VoiceNoteConstants.mimeType)
        let durationMs = intValue(info["duration"]) ?? 0
        let from = MatrixTimelineMapper.sender(matrixUserId: outer.sender ?? "", isOwn: isOwn)

        Task { [weak self] in
            guard let self, let data = await self.session.downloadMedia(file: file) else { return }
            let base64 = data.base64EncodedString()
            switch kind {
            case .image:
                self.handleInnerMessage(InnerMessage(
                    t: .image, id: id, from: from,
                    body: .image(.init(dataBase64: base64, mimeType: mimeType)), ts: ts))
            case .audio:
                let waveform = VoiceWaveformBuilder.decodeWaveform(from: data)
                self.handleInnerMessage(InnerMessage(
                    t: .audio, id: id, from: from,
                    body: .audio(.init(dataBase64: base64, mimeType: mimeType, durationMs: durationMs, waveform: waveform)), ts: ts))
            }
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
        // Race-free own-echo dedup (protocol C/D): the homeserver echoes our own
        // send back via sync, carrying `unsigned.transaction_id` == the localId we
        // sent. On a fast connection that echo can arrive BEFORE the send HTTP
        // response that gives the local row its `matrixEventId`, so the
        // matrixEventId-keyed suppression in handleInnerMessage misses and a second
        // bubble renders. transaction_id is known instantly, so reconcile here:
        // stamp the event_id, flip .sending→.sent, and DON'T render again. This only
        // matches THIS device's just-sent .sending row (msgId == localId == txn id);
        // the same account's send from ANOTHER device has no such row and falls
        // through to render normally.
        if isOwn, let txnId = outer.transactionId,
           messages.contains(where: { $0.msgId == txnId }) {
            handleSentEventId(localId: txnId, eventId: outer.eventId ?? "")
            return
        }

        let isEdit = relation?.relType == "m.replace"
        let pushFlag = cleartextPushFlag(outer)
        let streamLive = MatrixTimelineMapper.shouldStream(
            live: live,
            isOwn: isOwn,
            isEdit: isEdit,
            pushFlag: pushFlag
        )
        let body: String
        if isEdit, let newContent = content["m.new_content"] as? [String: Any],
           let edited = newContent["body"] as? String {
            body = edited
        } else {
            body = content["body"] as? String ?? ""
        }
        guard !body.isEmpty else { return }
        if Self.isPureToolTranscript(body) {
            AppLog.log(
                "🧰 dropping tool transcript text room=%@ event_id=%@",
                roomId,
                outer.eventId ?? "nil"
            )
            return
        }

        let streamKey = (isEdit ? relation?.eventId : outer.eventId) ?? outer.eventId ?? UUID().uuidString
        if !streamLive, let active = mapper.activeStreamId, active != streamKey,
           let emit = mapper.finalize(streamId: active, senderId: outer.sender ?? "") {
            applyEmit(emit, ts: ts)
        }
        let emits = mapper.ingest(
            eventId: streamKey,
            body: body,
            senderId: outer.sender ?? "",
            isOwn: isOwn,
            live: streamLive
        )
        for emit in emits { applyEmit(emit, ts: ts) }
        if MatrixTimelineMapper.isFinalEdit(isEdit: isEdit, pushFlag: pushFlag),
           let emit = mapper.finalize(streamId: streamKey, senderId: outer.sender ?? "") {
            applyEmit(emit, ts: ts)
        }
    }

    /// chat4000.tool (protocol E, START-ONLY): one static chip per tool_id.
    private func handleTool(content: [String: Any], sender: String?, ts: Int64) {
        guard let tool = content["chat4000.tool"] as? [String: Any] else { return }
        let toolId = tool["tool_id"] as? String ?? UUID().uuidString
        let from = MatrixTimelineMapper.sender(matrixUserId: sender ?? "", isOwn: false)
        AppLog.log("🔧 tool room=%@ name=%@ id=%@ icon=%@",
                   roomId, tool["name"] as? String ?? "?", toolId, tool["icon"] as? String ?? "-")
        guard emittedToolStarts.insert(toolId).inserted else { return }
        handleInnerMessage(InnerMessage(
            t: .toolStart, id: UUID().uuidString, from: from,
            body: .toolStart(.init(
                toolId: toolId,
                name: tool["name"] as? String ?? "tool",
                args: "",
                icon: tool["icon"] as? String)), ts: ts))
    }

    private func handleStatus(content: [String: Any], ts: Int64) {
        guard let state = content["state"] as? String else { return }
        let mapped: String
        switch state {
        case "idle", "typing", "thinking", "working": mapped = state
        default: mapped = "working"
        }
        AppLog.log("📊 status room=%@ state=%@ mapped=%@ ts=%@", roomId, state, mapped, String(ts))
        handleInnerMessage(InnerMessage(
            t: .status, id: UUID().uuidString,
            from: SenderInfo(role: .plugin, deviceId: "", deviceName: ""),
            body: .status(.init(status: mapped)), ts: ts))
    }

    private func applyEmit(_ emit: MatrixTimelineMapper.Emit, ts: Int64) {
        switch emit {
        case let .text(id, body, senderId, isOwn):
            handleInnerMessage(InnerMessage(
                t: .text, id: id,
                from: MatrixTimelineMapper.sender(matrixUserId: senderId, isOwn: isOwn),
                body: .text(.init(text: body)), ts: ts))
        case let .delta(streamId, delta, senderId):
            handleInnerMessage(InnerMessage(
                t: .textDelta, id: UUID().uuidString,
                from: MatrixTimelineMapper.sender(matrixUserId: senderId, isOwn: false),
                body: .textDelta(.init(delta: delta, streamId: streamId)), ts: ts))
        case let .end(streamId, body, senderId):
            handleInnerMessage(InnerMessage(
                t: .textEnd, id: UUID().uuidString,
                from: MatrixTimelineMapper.sender(matrixUserId: senderId, isOwn: false),
                body: .textEnd(.init(text: body, reset: nil, streamId: streamId)), ts: ts))
        }
    }

    // MARK: - InnerMessage → ChatMessage rendering

    private func handleInnerMessage(_ inner: InnerMessage) {
        if let from = inner.from, from.role == .app {
            // An own-ACCOUNT message arriving via sync. Suppress it ONLY if a local
            // row already carries this event_id — that means it's the echo of a send
            // from THIS device (reconciled by handleSentEventId) and is already on
            // screen. A message sent from ANOTHER device on the same account has an
            // event_id we've never seen, so it falls through and renders. (The old
            // guard keyed on `deviceId == currentDeviceId`, which the timeline mapper
            // stamps on EVERY own message regardless of origin — so it wrongly
            // dropped this account's messages sent from other devices.)
            if messages.contains(where: { $0.matrixEventId == inner.id })
                || storedMessageExists(matrixEventId: inner.id) {
                return
            }
        }

        let sender = messageSender(for: inner)
        switch inner.body {
        case .text(let b):
            receiveText(b.text, id: inner.id, sender: sender, ts: inner.ts)
        case .image(let b):
            receiveImage(dataBase64: b.dataBase64, id: inner.id, sender: sender, ts: inner.ts)
        case .audio(let b):
            receiveAudio(dataBase64: b.dataBase64, mimeType: b.mimeType, durationMs: b.durationMs,
                         waveform: b.waveform, id: inner.id, sender: sender, ts: inner.ts)
        case .textDelta(let b):
            let streamId = b.streamId ?? inner.id
            if currentStreamId != streamId {
                guard beginStreamingMessage(streamId: streamId, sender: sender, ts: inner.ts) else { return }
            }
            currentStreamText += b.delta
            updateCurrentStreamingMessage(text: currentStreamText, sender: sender)
        case .textEnd(let b):
            let streamId = b.streamId ?? inner.id
            if b.reset == true {
                cancelCurrentStreamingMessage(streamId: streamId)
            } else if currentStreamId == streamId {
                finalizeCurrentStreamingMessage(text: b.text, sender: sender, ts: inner.ts)
            } else if isDuplicateInnerId(streamId) {
                AppLog.log("🧵 textEnd skipping duplicate stream_id=%@", streamId)
            } else if currentStreamId == nil {
                receiveText(b.text, id: streamId, sender: sender, ts: inner.ts)
            }
        case .status(let s):
            guard sender == .agent else { break }
            guard inner.ts > latestStatusTs else { break }
            latestStatusTs = inner.ts
            switch s.status {
            case "thinking": markBusy(phase: "Thinking", startTs: inner.ts)
            case "working": markBusy(phase: "Working", startTs: inner.ts)
            case "typing": markBusy(phase: "Typing", startTs: inner.ts)
            case "idle": clearBusy()
            default: break
            }
        case .ack(let a):
            if let from = inner.from, from.role == .plugin { handleInnerAck(refs: a.refs) }
        case .toolStart(let b):
            beginToolCallBubble(toolId: b.toolId, toolName: b.name, icon: b.icon, sender: sender, ts: inner.ts)
        case .toolDelta, .toolEnd:
            break // removed in the START-only model
        }
    }

    private func receiveText(_ text: String, id: String, sender: MessageSender, ts: Int64) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if replaceUnavailableMessage(id: id, sender: sender, configure: { message in
            message.text = text
            message.kind = .message
        }) { return }
        if isDuplicateInnerId(id) { return }
        let message = ChatMessage(msgId: id, text: text, sender: sender, timestamp: eventDate(ts), roomId: roomId)
        // A `.user` row reaching receiveText is our own message synced from ANOTHER
        // device (this device's sends are shown via local echo and suppressed). The
        // `id` IS the homeserver event_id, so stamp it on `matrixEventId` — without
        // it, the plugin's read receipt (handleRead matches on matrixEventId) can
        // never flip this row to .delivered, so cross-device sends would be stuck on
        // a single ✓ forever.
        if sender == .user { message.matrixEventId = id }
        guard appendAndInsertUnique(message, reason: "receive_text") else { return }
        Haptics.success()
        persistContext()
        requestScrollToBottom()
    }

    private func receiveImage(dataBase64: String, id: String, sender: MessageSender, ts: Int64) {
        guard let imageData = Data(base64Encoded: dataBase64) else { return }
        if replaceUnavailableMessage(id: id, sender: sender, configure: { message in
            message.text = ""
            message.imageData = imageData
            message.kind = .message
        }) { return }
        if isDuplicateInnerId(id) { return }
        let message = ChatMessage(msgId: id, imageData: imageData, sender: sender, timestamp: eventDate(ts), roomId: roomId)
        // Own image synced from another device: stamp the event_id so the peer read
        // receipt can flip its tick (mirrors receiveText) and so this device's later
        // echo of the same send is suppressed by matrixEventId.
        if sender == .user { message.matrixEventId = id }
        guard appendAndInsertUnique(message, reason: "receive_image") else { return }
        if sender == .agent { emitMessageReceived(kind: "image") }
        Haptics.success()
        persistContext()
        requestScrollToBottom()
    }

    private func receiveAudio(dataBase64: String, mimeType: String, durationMs: Int, waveform: [Float], id: String, sender: MessageSender, ts: Int64) {
        guard let audioData = Data(base64Encoded: dataBase64) else { return }
        if replaceUnavailableMessage(id: id, sender: sender, configure: { message in
            message.text = ""
            message.audioData = audioData
            message.audioMimeType = mimeType
            message.audioDuration = Double(durationMs) / 1000
            message.audioWaveformData = VoiceWaveformCodec.encode(waveform)
            message.kind = .message
        }) { return }
        if isDuplicateInnerId(id) { return }
        let message = ChatMessage(
            msgId: id, audioData: audioData, audioMimeType: mimeType,
            audioDuration: Double(durationMs) / 1000, audioWaveform: waveform,
            sender: sender, timestamp: eventDate(ts), roomId: roomId)
        if sender == .user { message.matrixEventId = id }
        guard appendAndInsertUnique(message, reason: "receive_audio") else { return }
        if sender == .agent { emitMessageReceived(kind: "audio") }
        Haptics.success()
        persistContext()
        requestScrollToBottom()
    }

    private func receiveHTMLCard(_ html: String, id: String, sender: MessageSender, ts: Int64) {
        // Render the card's HTML as-authored (full CSS + JS). The renderer
        // (HTMLCardBubble) is the security boundary: it runs in a WKWebView with
        // ALL network loads blocked, so no sanitizing/stripping happens here.
        let sanitizedHTML = html
        guard sanitizedHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }

        // SETTLE (don't delete) any agent text still streaming. A weather turn is
        // [text answer][tool][card]; on a live catch-up replay the text is left as an
        // un-finalized streaming bubble, and the old `cancelCurrentStreamingMessage`
        // here DELETED it — that's why "the first text never showed up". Finalizing
        // keeps the text and renders the card alongside it.
        settleOpenStream()

        if replaceUnavailableMessage(id: id, sender: sender, configure: { message in
            message.text = ""
            message.kind = .htmlCard
            message.htmlCardHTML = sanitizedHTML
        }) { return }

        if isDuplicateInnerId(id) { return }
        let message = ChatMessage(
            msgId: id,
            text: "",
            sender: sender,
            timestamp: eventDate(ts),
            roomId: roomId,
            kind: .htmlCard,
            htmlCardHTML: sanitizedHTML
        )
        guard appendAndInsertUnique(message, reason: "receive_html_card") else { return }
        if sender == .agent { emitMessageReceived(kind: "html_card") }
        Haptics.success()
        persistContext()
        requestScrollToBottom()
    }

    /// CL18 `message_received` — a FINAL agent answer landed (one of text | image |
    /// audio | html_card). Fires once per unique message (called past the dedup/
    /// append guards). `turn_duration_bucket` is derived from the busy clock (B2):
    /// final-answer now minus `busyStartTime` (the turn's earliest `chat4000.status`
    /// ts); OMITTED entirely when no status preceded the answer.
    private func emitMessageReceived(kind: String) {
        var props: [String: Any] = ["kind": kind]
        if let start = busyStartTime {
            props["turn_duration_bucket"] = AnalyticsBuckets.turnDurationBucket(
                for: Date().timeIntervalSince(start))
        }
        TelemetryManager.shared.track(.messageReceived, properties: props)
    }

    private func receiveUnavailable(id: String, sender: MessageSender, ts: Int64) {
        if isDuplicateInnerId(id) { return }
        let message = ChatMessage(
            msgId: id,
            text: "Message unavailable on this device",
            sender: sender,
            timestamp: eventDate(ts),
            roomId: roomId,
            kind: .unavailable
        )
        guard appendAndInsertUnique(message, reason: "receive_unavailable") else { return }
        persistContext()
        requestScrollToBottom()
    }

    private func replaceUnavailableMessage(
        id: String,
        sender: MessageSender,
        configure: (ChatMessage) -> Void
    ) -> Bool {
        guard let message = messages.first(where: { $0.msgId == id && $0.kind == .unavailable }) else {
            return false
        }
        message.sender = sender
        message.imageData = nil
        message.audioData = nil
        message.audioMimeType = nil
        message.audioDuration = nil
        message.audioWaveformData = nil
        message.htmlCardHTML = nil
        configure(message)
        persistContext()
        requestScrollToBottom()
        return true
    }

    private func beginStreamingMessage(streamId: String, sender: MessageSender, ts: Int64) -> Bool {
        if isDuplicateInnerId(streamId) {
            AppLog.log("🧵 beginStreamingMessage skipping duplicate stream_id=%@", streamId)
            return false
        }
        currentStreamId = streamId
        currentStreamText = ""
        if let existing = currentStreamingMessage(), existing.sender == sender, existing.status == .sending {
            existing.text = ""
            existing.msgId = streamId
        } else {
            let message = ChatMessage(msgId: streamId, text: "", sender: sender, timestamp: eventDate(ts), status: .sending, roomId: roomId)
            guard appendAndInsertUnique(message, reason: "stream_begin") else { return false }
            currentStreamMessageId = message.id
        }
        requestScrollToBottom()
        return true
    }

    /// Settle the currently-open agent stream as a finished row, preserving its
    /// text. Called when something other than a `text_end` interrupts the stream
    /// (e.g. an html_card in the same turn). An empty placeholder (stream begun but
    /// no delta yet) is removed instead, so no blank bubble is left behind.
    private func settleOpenStream() {
        guard let streamId = currentStreamId else { return }
        if currentStreamText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cancelCurrentStreamingMessage(streamId: streamId)
        } else {
            let sender = currentStreamingMessage()?.sender ?? .agent
            finalizeCurrentStreamingMessage(text: currentStreamText, sender: sender, ts: 0)
        }
    }

    private func updateCurrentStreamingMessage(text: String, sender: MessageSender) {
        if let existing = currentStreamingMessage(), existing.sender == sender, existing.status == .sending {
            existing.text = text
        } else if let streamId = currentStreamId, isDuplicateInnerId(streamId) {
            AppLog.log("🧵 updateCurrentStreamingMessage skipping duplicate stream_id=%@", streamId)
        } else {
            guard let streamId = currentStreamId else {
                AppLog.log("🧵 updateCurrentStreamingMessage missing stream_id room=%@", roomId)
                return
            }
            let message = ChatMessage(msgId: streamId, text: text, sender: sender, status: .sending, roomId: roomId)
            guard appendAndInsertUnique(message, reason: "stream_update") else { return }
            currentStreamMessageId = message.id
        }
        requestScrollToBottom()
    }

    private func finalizeCurrentStreamingMessage(text: String, sender: MessageSender, ts: Int64) {
        Haptics.success()
        if let existing = currentStreamingMessage(), existing.sender == sender, existing.status == .sending {
            existing.text = text
            existing.status = .sent
        } else if let streamId = currentStreamId, isDuplicateInnerId(streamId) {
            AppLog.log("🧵 finalize skipping duplicate stream_id=%@", streamId)
        } else if let streamId = currentStreamId {
            let message = ChatMessage(msgId: streamId, text: text, sender: sender, timestamp: eventDate(ts), roomId: roomId)
            _ = appendAndInsertUnique(message, reason: "stream_finalize")
        }
        // CL18 — the streamed agent answer settled (streaming is always a live
        // agent turn).
        if sender == .agent { emitMessageReceived(kind: "text") }
        currentStreamId = nil
        currentStreamText = ""
        currentStreamMessageId = nil
        persistContext()
        requestScrollToBottom()
    }

    private func cancelCurrentStreamingMessage(streamId: String) {
        if currentStreamId == streamId, let existing = currentStreamingMessage() {
            withAnimation(.easeOut(duration: 0.2)) {
                if let index = messages.firstIndex(where: { $0.id == existing.id }) {
                    messages.remove(at: index)
                }
            }
            modelContext?.delete(existing)
            persistContext()
        }
        if currentStreamId == streamId {
            currentStreamId = nil
            currentStreamText = ""
            currentStreamMessageId = nil
        }
        requestScrollToBottom()
    }

    private func currentStreamingMessage() -> ChatMessage? {
        guard let currentStreamMessageId else { return nil }
        return messages.first(where: { $0.id == currentStreamMessageId })
    }

    private func beginToolCallBubble(toolId: String, toolName: String, icon: String?, sender: MessageSender, ts: Int64) {
        AppLog.log("🔧 toolCall chip room=%@ id=%@ name=%@", roomId, toolId, toolName)
        guard !messages.contains(where: { $0.kind == .toolCall && $0.toolId == toolId }) else { return }
        // roomId is FIXED to this view model — never a shared activeRoomId. This
        // is the structural fix for the tool-bleed: a chip can only ever land in
        // its own room.
        let bubble = ChatMessage(
            sender: sender, timestamp: eventDate(ts), roomId: roomId, kind: .toolCall,
            toolId: toolId, toolName: toolName, toolIcon: icon)
        guard appendAndInsertUnique(bubble, reason: "tool_call") else { return }
        persistContext()
        requestScrollToBottom()
    }

    private func messageSender(for inner: InnerMessage) -> MessageSender {
        guard let from = inner.from else { return .agent }
        switch from.role {
        case .app: return .user
        case .plugin, .unknown: return .agent
        }
    }

    private func isDuplicateInnerId(_ id: String) -> Bool {
        if messages.contains(where: { $0.msgId == id }) { return true }
        return storedMessageExists(msgId: id)
    }

    // MARK: - Ack / read routing (broadcast from the global model)

    /// The send completed → remember the homeserver event_id on the matching row and
    /// flip it from `.sending` (clock) to `.sent` (one tick). This is the ONLY place
    /// an outbound row becomes `.sent`: it now reflects a real delivery to the
    /// homeserver, not an optimistic guess made before the socket was even up.
    func handleSentEventId(localId: String, eventId: String) {
        guard let row = messages.first(where: { $0.msgId == localId }) else { return }
        row.matrixEventId = eventId
        if row.status == .sending { row.status = .sent }
        persistContext()
    }

    /// A peer read receipt "up to `eventId`" → mark the matching outbound row AND
    /// every earlier still-unacked user row delivered. A Matrix read receipt is
    /// CUMULATIVE: "read up to E" means everything at or before E is read. The
    /// plugin's receipt frequently points at a LATER event (its own reply that
    /// arrived after your message), so an exact-match-only flip would leave your
    /// message stuck on a single ✓ even though it was read. We anchor on the
    /// receipt event's timestamp when it's in our timeline; otherwise we fall back
    /// to flipping just the exact match (safe — never flips a not-yet-read row).
    func handleRead(eventId: String) {
        // The receipt's target event, located in this room's timeline (it may be
        // one of our sends, an agent reply, or absent if it was a dropped event).
        let anchorTs = messages.first(where: {
            $0.matrixEventId == eventId || $0.msgId == eventId
        })?.timestamp
        var changed = false
        for row in messages
        where row.sender == .user && (row.status == .sending || row.status == .sent) {
            let coveredByAnchor = anchorTs.map { row.timestamp <= $0 } ?? false
            guard row.matrixEventId == eventId || coveredByAnchor else { continue }
            row.status = .delivered
            changed = true
        }
        if changed { persistContext() }
    }

    /// Plugin emitted an end-to-end ack for an outbound message → "delivered" tick.
    private func handleInnerAck(refs: String) {
        guard let match = messages.first(where: { $0.msgId == refs }) else { return }
        if match.status == .sending || match.status == .sent {
            match.status = .delivered
            persistContext()
        }
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

    private func cleartextPushFlag(_ outer: SyncEvent) -> Bool? {
        guard let obj = json(outer.rawJSON),
              let content = obj["content"] as? [String: Any] else {
            return nil
        }
        return content["chat4000.push"] as? Bool
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        case let d as Double: return Int(d)
        default: return nil
        }
    }

    // MARK: - Busy clock (per room; no shared dictionary)

    private func markBusy(phase: String, startTs: Int64) {
        // Anchor the elapsed clock to the turn's true start (status
        // origin_server_ts), keeping the earliest seen — stable across switches.
        let eventStart = startTs > 0 ? Date(timeIntervalSince1970: Double(startTs) / 1000) : .now
        let start = busyStartTime.map { min($0, eventStart) } ?? eventStart
        busyStartTime = start
        busyPhase = phase
        isAgentBusy = true
        scheduleBusyTTL(statusTs: startTs)
    }

    private func clearBusy() {
        busyTTLTask?.cancel()
        busyTTLTask = nil
        isAgentBusy = false
        busyStartTime = nil
    }

    /// Stuck-spinner guard keyed on origin_server_ts: clears 10s after the latest
    /// status's SERVER timestamp, so a late/batched status already ≥10s old clears
    /// immediately and a redelivered old status can never extend the label.
    private func scheduleBusyTTL(statusTs: Int64) {
        busyTTLTask?.cancel()
        busyTTLTask = nil
        let nowMs = Date().timeIntervalSince1970 * 1000
        let delay = (Double(statusTs) + 10_000 - nowMs) / 1000
        guard delay > 0 else {
            clearBusy()
            return
        }
        busyTTLTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.clearBusy()
        }
    }

    // MARK: - Outbound (only the front room sends; each uses its own roomId)

    // Sends go through the session OUTBOX: the row stays `.sending` (clock) until the
    // send actually returns a homeserver event_id, which flips it to `.sent` via
    // `handleSentEventId`. When offline / not yet keyed, the outbox holds it and
    // flushes on connect — no optimistic `.sent` that lies about an un-sent message.

    func send(text: String) {
        let localId = UUID().uuidString
        let message = ChatMessage(msgId: localId, text: text, sender: .user, status: .sending, roomId: roomId)
        guard appendAndInsertUnique(message, reason: "send_text") else { return }
        persistContext()
        forceScrollToBottom()

        session.enqueueSend(.text(text), roomId: roomId, localId: localId)
        TelemetryManager.shared.track(
            .messageSentText,
            properties: ["source": "keyboard", "length_bucket": AnalyticsBuckets.lengthBucket(for: text)]
        )
    }

    func sendImage(data: Data, mimeType: String, source: String) {
        let localId = UUID().uuidString
        let message = ChatMessage(msgId: localId, imageData: data, sender: .user, status: .sending, roomId: roomId)
        guard appendAndInsertUnique(message, reason: "send_image") else { return }
        persistContext()
        forceScrollToBottom()

        session.enqueueSend(.image(data, mimeType: mimeType), roomId: roomId, localId: localId)
        TelemetryManager.shared.track(.messageSentImage, properties: ["source": source, "count": 1])
        Haptics.impact()
    }

    func sendAudio(data: Data, mimeType: String, duration: TimeInterval, waveform: [Float], source: String) {
        let localId = UUID().uuidString
        let message = ChatMessage(
            msgId: localId,
            audioData: data, audioMimeType: mimeType, audioDuration: duration,
            audioWaveform: waveform, sender: .user, status: .sending, roomId: roomId)
        guard appendAndInsertUnique(message, reason: "send_audio") else { return }
        persistContext()
        forceScrollToBottom()

        session.enqueueSend(
            .audio(data, mimeType: mimeType, durationMs: Int((duration * 1000).rounded())),
            roomId: roomId, localId: localId)
        TelemetryManager.shared.track(
            .messageSentAudio,
            properties: ["source": source, "duration_bucket": AnalyticsBuckets.durationBucket(for: duration)]
        )
    }

    func markRead() {
        guard let eventId = lastEventId else { return }
        Task { await session.sendReadReceipt(roomId: roomId, eventId: eventId) }
    }

    func clearHistory() {
        for message in messages { modelContext?.delete(message) }
        persistContext()
        messages.removeAll()
        requestScrollToBottom()
    }
}
