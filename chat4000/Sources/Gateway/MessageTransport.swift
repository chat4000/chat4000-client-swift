import Foundation

/// Session-time messaging facade per protocol §6.6.11.
///
/// Hides everything below the application layer — WebSocket lifecycle,
/// XChaCha20-Poly1305 encryption, outer envelope construction, the §6.6
/// ack flow (`seq`, `recv_ack`, `relay_recv_ack`, `last_acked_seq`),
/// dedup by `inner.id`, reconnect-with-backoff, in-order delivery on
/// redrive. Consumers (ChatViewModel, push-wake service) call `send`,
/// observe `onReceive` / `onStatus` / `onConnectionState`, and never
/// touch sockets, ciphertext, `seq`, or any of the recovery state.
///
/// **Scope: session-time only.** Pairing is explicitly NOT in scope.
/// Pairing runs before the group key exists, uses a different frame
/// family (`pair_open` / `pair_data` / `pair_complete` / `pair_cancel`),
/// routes by `room_id` not `group_id`, and has no overlap with the §6.6
/// ack machinery. Pairing remains in `PairingService`. A
/// `MessageTransport` instance must only be constructed after pairing
/// has succeeded and a stable group key is available.
@MainActor
protocol MessageTransport: AnyObject {
    /// Coarse connection state for UI.
    var state: ConnectionState { get }

    /// The currently-bound group_id, if any.
    var currentGroupId: String? { get }

    /// Fire-and-forget send. Returns the wire-level `inner.id` immediately.
    /// The transport handles encryption, outbox, retries, reconnect.
    @discardableResult
    func send(_ msg: OutboundMessage) -> String

    /// Inbound dispatch. Called once per `inner.id`, after dedup + decrypt,
    /// in send order. Inner `ack` messages flow through here unchanged —
    /// the transport does NOT interpret them. The consumer is responsible
    /// for finding outbound rows whose `msgId == ack.refs` and flipping
    /// status to `.delivered` (per §6.6.7 the "delivered" tick is an
    /// application-layer event).
    var onReceive: ((InnerMessage) -> Void)? { get set }

    /// Outbound transport-layer status updates. Emits:
    ///   `.sent`   on `relay_recv_ack` matching the outbound `msg_id`
    ///   `.failed` on local timeout / socket error
    /// Does **not** emit `.delivered` — that signal is application-layer
    /// (an inner `ack` from `from.role == "plugin"`).
    var onStatus: ((MessageStatusUpdate) -> Void)? { get set }

    /// Coarse connection state changes for UI banners and instrumentation.
    var onConnectionState: ((ConnectionState) -> Void)? { get set }

    /// Optional callback for protocol-version-policy hello_ok payload.
    /// Forwarded so consumers can drive upgrade banners. The transport
    /// itself does not interpret the policy.
    var onTermsVersionUpdate: ((Int) -> Void)? { get set }

    func connect(config: GroupConfig)
    func disconnect()
}

/// What a consumer hands the transport. The transport translates this
/// into a fully-formed `InnerMessage`, encrypts, wraps in the outer
/// envelope, and ships.
enum OutboundMessage {
    case text(String)
    case image(data: Data, mimeType: String)
    case audio(data: Data, mimeType: String, durationMs: Int, waveform: [Float])
    case textDelta(streamId: String, delta: String)
    case textEnd(streamId: String, text: String, reset: Bool? = nil)
    case status(String)
    /// End-to-end application-layer acknowledgement (§6.6.5). Travels
    /// inside the encrypted envelope. The transport does not synthesize
    /// these — only the consumer (e.g. plugin) decides when to emit one.
    case ack(refs: String, stage: InnerAckStage)
}

/// Per-msg outbound status surfaced to the consumer. Drives the local
/// `MessageStatus` field on `ChatMessage`. Per §6.6.7 only the transport
/// layer states (sent/failed) are emitted here; the application layer
/// determines `.delivered` from inner `ack` frames.
struct MessageStatusUpdate {
    let msgId: String
    let status: TransportStatus

    enum TransportStatus {
        /// Relay accepted, queued, and fanned out the outbound message
        /// (driven by `relay_recv_ack`).
        case sent
        /// Transport-layer error (timeout, socket error, encode failure).
        case failed
    }
}
