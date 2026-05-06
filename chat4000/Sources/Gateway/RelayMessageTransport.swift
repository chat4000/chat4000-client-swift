import Foundation

/// Default `MessageTransport` implementation backed by `RelayClient`.
///
/// Wraps the existing relay client with the cleaner facade the rest of
/// the app should be coding against. Translates between the consumer-
/// facing `OutboundMessage` enum and the wire-level `InnerMessage`,
/// and adapts the underlying callbacks into the new shape.
///
/// **Scope reminder (§6.6.11):** session-time messaging only. Pairing
/// is handled by `PairingService` and runs entirely before this class
/// exists. Construct a `RelayMessageTransport` only after pairing has
/// produced a stable group key.
@MainActor
@Observable
final class RelayMessageTransport: MessageTransport {
    /// Backing relay client — owns the WebSocket, hello/handshake,
    /// `seq` parsing, `AckTracker`, `AckSeqStore`, ping/pong, App Nap
    /// blocker, plugin-version-policy observation.
    let relay: RelayClient

    var onReceive: ((InnerMessage) -> Void)?
    var onStatus: ((MessageStatusUpdate) -> Void)?
    var onConnectionState: ((ConnectionState) -> Void)?
    var onTermsVersionUpdate: ((Int) -> Void)?

    var state: ConnectionState { relay.state }
    var currentGroupId: String? { relay.currentGroupId }

    /// Tracks state transitions on `relay.state` so `onConnectionState`
    /// fires on changes only.
    private var lastObservedState: ConnectionState = .disconnected
    private var stateObserverTask: Task<Void, Never>?

    init(relay: RelayClient = RelayClient()) {
        self.relay = relay
        wireRelayCallbacks()
        startStateObserver()
    }

    // MARK: - MessageTransport

    @discardableResult
    func send(_ msg: OutboundMessage) -> String {
        switch msg {
        case .text(let text):
            return relay.send(text: text)

        case .image(let data, let mimeType):
            return relay.sendImage(jpegData: data, mimeType: mimeType)

        case .audio(let data, let mimeType, let durationMs, let waveform):
            return relay.sendAudio(
                audioData: data,
                mimeType: mimeType,
                durationMs: durationMs,
                waveform: waveform
            )

        case .textDelta(let streamId, let delta):
            return relay.sendInnerMessage(
                .textDelta(streamId: streamId, delta: delta)
            )

        case .textEnd(let streamId, let text, let reset):
            return relay.sendInnerMessage(
                .textEnd(streamId: streamId, text: text, reset: reset)
            )

        case .status(let status):
            relay.sendStatus(status)
            // sendStatus is fire-and-forget without an inner.id surface
            // today; surface a placeholder so callers don't crash.
            return ""

        case .ack(let refs, let stage):
            return relay.sendInnerMessage(.ack(refs: refs, stage: stage))
        }
    }

    func connect(config: GroupConfig) {
        relay.connect(config: config)
    }

    func disconnect() {
        relay.disconnect()
    }

    // MARK: - Private wiring

    private func wireRelayCallbacks() {
        relay.onInnerMessage = { [weak self] inner, seq in
            self?.handleInbound(inner, seq: seq)
        }
        relay.onRelayRecvAck = { [weak self] msgId in
            self?.onStatus?(MessageStatusUpdate(msgId: msgId, status: .sent))
        }
        relay.onTermsVersionUpdate = { [weak self] currentTermsVersion in
            self?.onTermsVersionUpdate?(currentTermsVersion)
        }
    }

    private func handleInbound(_ inner: InnerMessage, seq: UInt64?) {
        // No transport-layer dedup. The consumer's persistence layer
        // (`isDuplicateInnerId` before SwiftData insert) is the authoritative
        // dedup gate per §6.6.9. Transport-layer dedup-by-inner.id was
        // removed because senders that still share `inner.id` across
        // streaming frames (per pre-spec §6.4.2) would otherwise have all
        // frames after the first dedup-skipped here.
        //
        // Per §6.6.11: inner messages of t == "ack" pass through untouched.
        // The consumer is responsible for finding the outbound row whose
        // msgId matches body.refs and flipping it to `.delivered`. The
        // transport does NOT emit a status update for "delivered" — that's
        // an application-layer determination.
        onReceive?(inner)

        // Per §6.6.3: record durable + live ack progress. Owned by the
        // transport so consumers never deal with seq.
        recordPersistedSeq(seq)
    }

    /// Per §6.6.3: hand the seq to the tracker, which owns both the live
    /// debounced `recv_ack` emission AND the durable `AckSeqStore` write
    /// (inside `AckTracker.emit`). Eagerly writing `AckSeqStore` here would
    /// poison the tracker's `seq > lastAcked` guard and silently suppress
    /// the recv_ack frame — the queue would then grow unbounded until the
    /// flow-control window-full-pause stalled the recipient.
    private func recordPersistedSeq(_ seq: UInt64?) {
        guard let seq, relay.currentGroupId != nil else { return }
        relay.ackTracker.recordPersisted(seq)
    }

    private func startStateObserver() {
        // The simplest reliable way to observe the underlying relay's
        // @Observable state without adding a callback contract: poll on
        // a tight loop and emit on transitions. Costs essentially
        // nothing and keeps RelayClient untouched.
        stateObserverTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                await MainActor.run {
                    guard let self else { return }
                    let current = self.relay.state
                    if current != self.lastObservedState {
                        self.lastObservedState = current
                        self.onConnectionState?(current)
                    }
                }
            }
        }
    }
}
