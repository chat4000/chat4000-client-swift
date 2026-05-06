import CryptoKit
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Protocol Constants

enum RelayProtocol {
    static let version = 1
    static let maxMessageSize = 4 * 1024 * 1024
    /// Application-layer ping cadence. 25s keeps the relay's 60s idle-ping
    /// timeout from ever firing under normal conditions and stops macOS App
    /// Nap from suspending the receive loop because there is regular outbound
    /// activity.
    static let heartbeatIntervalSecs: TimeInterval = 25
    static let defaultRelayURL = "wss://relay.chat4000.com/ws"
}

// MARK: - Wire Message Types

/// Matches relay's `MessageType` (serde snake_case).
enum RelayMessageType: String, Codable {
    // Pairing room
    case pairOpen = "pair_open"
    case pairOpenOk = "pair_open_ok"
    case pairReady = "pair_ready"
    case pairData = "pair_data"
    case pairComplete = "pair_complete"
    case pairCancel = "pair_cancel"

    // Registration
    case challenge
    case challengeOk = "challenge_ok"
    case register
    case registerOk = "register_ok"
    case registerError = "register_error"

    // Handshake
    case hello
    case helloOk = "hello_ok"
    case helloError = "hello_error"

    // Encrypted messages
    case msg

    // Reliable delivery (per protocol §6.6)
    case recvAck = "recv_ack"
    case relayRecvAck = "relay_recv_ack"

    // Keepalive
    case ping
    case pong
}

// MARK: - Outgoing Payloads

struct HelloPayload: Encodable {
    let role: String
    let groupId: String
    let deviceId: String?
    let deviceToken: String?
    let appId: String?
    let appVersion: String
    let releaseChannel: String
    /// Highest relay-assigned `seq` the client has stably persisted for this
    /// `(group_id, device_id)` triple (per protocol §6.1 + §6.6.8). Allows the
    /// relay to redrive only un-acked tail. Optional for legacy compat.
    let lastAckedSeq: UInt64?

    enum CodingKeys: String, CodingKey {
        case role
        case groupId = "group_id"
        case deviceId = "device_id"
        case deviceToken = "device_token"
        case appId = "app_id"
        case appVersion = "app_version"
        case releaseChannel = "release_channel"
        case lastAckedSeq = "last_acked_seq"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(groupId, forKey: .groupId)
        try c.encodeIfPresent(deviceId, forKey: .deviceId)
        try c.encodeIfPresent(deviceToken, forKey: .deviceToken)
        try c.encodeIfPresent(appId, forKey: .appId)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(releaseChannel, forKey: .releaseChannel)
        try c.encodeIfPresent(lastAckedSeq, forKey: .lastAckedSeq)
    }
}

struct HelloOkPayload: Decodable {
    let currentTermsVersion: Int?
    let versionPolicy: VersionPolicy?
    let pluginVersionPolicy: VersionPolicy?

    enum CodingKeys: String, CodingKey {
        case currentTermsVersion = "current_terms_version"
        case versionPolicy = "version_policy"
        case pluginVersionPolicy = "plugin_version_policy"
    }
}

struct RegisterPayload: Encodable {
    let groupId: String
    let attestation: String
    let challenge: String

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case attestation, challenge
    }
}

struct MsgPayload: Codable {
    let nonce: String
    let ciphertext: String
    let msgId: String
    let notifyIfOffline: Bool?
    /// Relay-assigned per-recipient monotonic sequence number (per protocol
    /// §6.4 + §6.6.3). Present only on relay-→client deliveries; senders MUST
    /// NOT set this on outbound msg envelopes.
    let seq: UInt64?

    enum CodingKeys: String, CodingKey {
        case nonce, ciphertext
        case msgId = "msg_id"
        case notifyIfOffline = "notify_if_offline"
        case seq
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nonce, forKey: .nonce)
        try c.encode(ciphertext, forKey: .ciphertext)
        try c.encode(msgId, forKey: .msgId)
        try c.encodeIfPresent(notifyIfOffline, forKey: .notifyIfOffline)
        try c.encodeIfPresent(seq, forKey: .seq)
    }
}

/// Per protocol §6.6.3 — client → relay persistence acknowledgement (Flow A).
struct RecvAckPayload: Encodable {
    let upToSeq: UInt64
    let ranges: [[UInt64]]?

    enum CodingKeys: String, CodingKey {
        case upToSeq = "up_to_seq"
        case ranges
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(upToSeq, forKey: .upToSeq)
        try c.encodeIfPresent(ranges, forKey: .ranges)
    }
}

/// Per protocol §6.6.4 — relay → originating client receipt for an outbound
/// message. Drives the "✓ sent" tick. Optional in v1; clients MUST NOT depend
/// on it for correctness.
struct RelayRecvAckPayload: Decodable {
    let msgId: String
    let queuedFor: [String]?

    enum CodingKeys: String, CodingKey {
        case msgId = "msg_id"
        case queuedFor = "queued_for"
    }
}

struct PairOpenPayload: Encodable {
    let role: String
    let roomId: String

    enum CodingKeys: String, CodingKey {
        case role
        case roomId = "room_id"
    }
}

struct PairDataPayload: Codable {
    let t: String
    let salt: String?
    let proof: String?
    let wrappedKey: WrappedGroupKey?

    enum CodingKeys: String, CodingKey {
        case t, salt, proof
        case wrappedKey = "wrapped_key"
    }
}

struct PairCompletePayload: Encodable {
    let status: String
}

struct PairCancelPayload: Encodable {
    let reason: String
}

struct WrappedGroupKey: Codable, Equatable {
    let ephemeralPub: String
    let nonce: String
    let ciphertext: String

    enum CodingKeys: String, CodingKey {
        case ephemeralPub = "ephemeral_pub"
        case nonce, ciphertext
    }
}

// MARK: - Incoming Payloads

struct ChallengeOkPayload: Decodable {
    let nonce: String
    let expiresInSecs: Int

    enum CodingKeys: String, CodingKey {
        case nonce
        case expiresInSecs = "expires_in_secs"
    }
}

struct RegisterOkPayload: Decodable {
    let groupId: String

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
    }
}

struct ErrorPayload: Decodable {
    let code: String
    let message: String
}

// MARK: - Parsed Incoming Message

/// All possible messages the app can receive from the relay.
enum RelayMessage {
    case pairOpenOk
    case pairReady
    case pairData(PairDataMessage)
    case pairComplete
    case pairCancel

    case challengeOk(nonce: String, expiresInSecs: Int)
    case registerOk(groupId: String)
    case registerError(code: String, message: String)
    case helloOk(currentTermsVersion: Int, versionPolicy: VersionPolicy?, pluginVersionPolicy: VersionPolicy?)
    case helloError(code: String, message: String)
    case msg(nonce: String, ciphertext: String, msgId: String, seq: UInt64?)
    case relayRecvAck(msgId: String, queuedFor: [String]?)
    case pong

    /// Parse a raw WebSocket text frame into a typed message.
    static func parse(from text: String) -> RelayMessage? {
        guard let data = text.data(using: .utf8) else { return nil }
        return parse(from: data)
    }

    static func parse(from data: Data) -> RelayMessage? {
        struct Header: Decodable {
            let version: Int
            let type: String
        }

        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { return nil }
        guard let type = RelayMessageType(rawValue: header.type) else {
            // Legacy outer activity frames were removed from the transport layer.
            // Treat them as ignored so only encrypted inner `status` messages
            // drive UI activity state.
            switch header.type {
            case "typing", "typing_stop":
                return nil
            default:
                return nil
            }
        }

        switch type {
        case .pairOpenOk:
            return .pairOpenOk

        case .pairReady:
            return .pairReady

        case .pairData:
            guard let env = try? JSONDecoder().decode(Envelope<PairDataPayload>.self, from: data) else { return nil }
            switch env.payload.t {
            case "hello":
                guard let salt = env.payload.salt else { return nil }
                return .pairData(.hello(salt: salt))
            case "join":
                guard let salt = env.payload.salt else { return nil }
                return .pairData(.join(salt: salt))
            case "proof_b":
                guard let proof = env.payload.proof else { return nil }
                return .pairData(.proofB(proof: proof))
            case "grant":
                guard let proof = env.payload.proof,
                      let wrappedKey = env.payload.wrappedKey
                else { return nil }
                return .pairData(.grant(proof: proof, wrappedKey: wrappedKey))
            default:
                return nil
            }

        case .pairCancel:
            return .pairCancel

        case .pairComplete:
            return .pairComplete

        case .challengeOk:
            guard let env = try? JSONDecoder().decode(Envelope<ChallengeOkPayload>.self, from: data) else { return nil }
            return .challengeOk(nonce: env.payload.nonce, expiresInSecs: env.payload.expiresInSecs)

        case .registerOk:
            guard let env = try? JSONDecoder().decode(Envelope<RegisterOkPayload>.self, from: data) else { return nil }
            return .registerOk(groupId: env.payload.groupId)

        case .registerError:
            guard let env = try? JSONDecoder().decode(Envelope<ErrorPayload>.self, from: data) else { return nil }
            return .registerError(code: env.payload.code, message: env.payload.message)

        case .helloOk:
            guard let env = try? JSONDecoder().decode(Envelope<HelloOkPayload>.self, from: data) else { return nil }
            return .helloOk(
                currentTermsVersion: env.payload.currentTermsVersion ?? 0,
                versionPolicy: env.payload.versionPolicy,
                pluginVersionPolicy: env.payload.pluginVersionPolicy
            )

        case .helloError:
            guard let env = try? JSONDecoder().decode(Envelope<ErrorPayload>.self, from: data) else { return nil }
            return .helloError(code: env.payload.code, message: env.payload.message)

        case .msg:
            guard let env = try? JSONDecoder().decode(Envelope<MsgPayload>.self, from: data) else { return nil }
            return .msg(
                nonce: env.payload.nonce,
                ciphertext: env.payload.ciphertext,
                msgId: env.payload.msgId,
                seq: env.payload.seq
            )

        case .relayRecvAck:
            guard let env = try? JSONDecoder().decode(Envelope<RelayRecvAckPayload>.self, from: data) else { return nil }
            return .relayRecvAck(msgId: env.payload.msgId, queuedFor: env.payload.queuedFor)

        case .pong:
            return .pong

        // Messages the app sends, not receives
        case .pairOpen, .challenge, .register, .hello, .ping, .recvAck:
            return nil
        }
    }
}

enum PairDataMessage: Equatable {
    case hello(salt: String)
    case join(salt: String)
    case proofB(proof: String)
    case grant(proof: String, wrappedKey: WrappedGroupKey)
}

// MARK: - Envelope (for typed decoding)

private struct Envelope<P: Decodable>: Decodable {
    let version: Int
    let type: RelayMessageType
    let payload: P
}

// MARK: - Outgoing Envelope Builder

enum RelayOutgoing {
    static func pairOpen(role: String, roomId: String) -> String? {
        encode(type: .pairOpen, payload: PairOpenPayload(role: role, roomId: roomId))
    }

    static func pairHello(salt: String) -> String? {
        encode(type: .pairData, payload: PairDataPayload(t: "hello", salt: salt, proof: nil, wrappedKey: nil))
    }

    static func pairJoin(salt: String) -> String? {
        encode(type: .pairData, payload: PairDataPayload(t: "join", salt: salt, proof: nil, wrappedKey: nil))
    }

    static func pairProofB(_ proof: String) -> String? {
        encode(type: .pairData, payload: PairDataPayload(t: "proof_b", salt: nil, proof: proof, wrappedKey: nil))
    }

    static func pairGrant(proof: String, wrappedKey: WrappedGroupKey) -> String? {
        encode(type: .pairData, payload: PairDataPayload(t: "grant", salt: nil, proof: proof, wrappedKey: wrappedKey))
    }

    static func pairComplete() -> String? {
        encode(type: .pairComplete, payload: PairCompletePayload(status: "ok"))
    }

    static func pairCancel(reason: String = "cancelled") -> String? {
        encode(type: .pairCancel, payload: PairCancelPayload(reason: reason))
    }

    static func challenge() -> String? {
        encode(type: .challenge, payload: EmptyObject())
    }

    static func register(groupId: String, attestation: String, challenge: String) -> String? {
        encode(type: .register, payload: RegisterPayload(groupId: groupId, attestation: attestation, challenge: challenge))
    }

    static func hello(
        groupId: String,
        deviceToken: String? = nil,
        appId: String? = AppRegistrationIdentity.currentAppId,
        deviceId: String = DeviceIdentity.currentDeviceId,
        lastAckedSeq: UInt64? = nil
    ) -> String? {
        encode(
            type: .hello,
            payload: HelloPayload(
                role: "app",
                groupId: groupId,
                deviceId: deviceId,
                deviceToken: deviceToken,
                appId: appId,
                appVersion: AppRegistrationIdentity.currentAppVersion,
                releaseChannel: AppRegistrationIdentity.currentReleaseChannel,
                lastAckedSeq: lastAckedSeq
            )
        )
    }

    static func msg(nonce: String, ciphertext: String, msgId: String, notifyIfOffline: Bool = true) -> String? {
        // Senders never assign `seq`; the relay rewrites it on the outbound copy.
        encode(
            type: .msg,
            payload: MsgPayload(
                nonce: nonce,
                ciphertext: ciphertext,
                msgId: msgId,
                notifyIfOffline: notifyIfOffline,
                seq: nil
            )
        )
    }

    static func recvAck(upToSeq: UInt64, ranges: [[UInt64]]? = nil) -> String? {
        encode(
            type: .recvAck,
            payload: RecvAckPayload(upToSeq: upToSeq, ranges: ranges)
        )
    }

    static func ping() -> String? {
        encodeNullPayload(type: .ping)
    }

    // MARK: - Private

    private struct OutEnvelope<P: Encodable>: Encodable {
        let version: Int
        let type: RelayMessageType
        let payload: P
    }

    private struct EmptyObject: Encodable {}

    private static func encode<P: Encodable>(type: RelayMessageType, payload: P) -> String? {
        let env = OutEnvelope(version: RelayProtocol.version, type: type, payload: payload)
        guard let data = try? JSONEncoder().encode(env) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// For messages where payload is JSON `null` (ping/pong).
    private static func encodeNullPayload(type: RelayMessageType) -> String? {
        let json: [String: Any] = [
            "version": RelayProtocol.version,
            "type": type.rawValue,
            "payload": NSNull(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum AppRegistrationIdentity {
    static var currentAppId: String? {
        guard let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty else { return nil }
        return bundleId
    }

    static var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var currentReleaseChannel: String {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        if bundleId.hasSuffix(".dev") { return "dev" }
        if bundleId.hasSuffix(".stage") { return "stage" }
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            return "testflight"
        }

        let distributionChannel = Bundle.main.object(forInfoDictionaryKey: "TelemetryDistributionChannel") as? String ?? "dev"
        switch distributionChannel {
        case "app_store":
            return "appstore"
        case "development":
            return "dev"
        default:
            return distributionChannel
        }
    }
}

// MARK: - Inner Message Types (plaintext inside encrypted msg)

/// Type discriminator for inner messages (inside the encrypted blob).
enum InnerMessageType: String, Codable {
    case text
    case image
    case audio
    case textDelta = "text_delta"
    case textEnd = "text_end"
    case status
    /// End-to-end "I received and decoded your message" ack (per §6.6.5).
    /// Drives the "✓✓ delivered" tick. Travels inside the encrypted envelope
    /// so the relay cannot forge it.
    case ack
}

/// Acknowledgement stage values per §6.6.5. `received` is the only required
/// stage for v1; `processing` and `displayed` are optional/reserved.
enum InnerAckStage: String, Codable {
    case received
    case processing
    case displayed
}

enum SenderRole: String, Codable {
    case app
    case plugin
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = SenderRole(rawValue: rawValue) ?? .unknown
    }
}

struct SenderInfo: Codable, Equatable {
    let role: SenderRole
    let deviceId: String
    let deviceName: String
    let appVersion: String?
    let bundleId: String?

    init(
        role: SenderRole,
        deviceId: String,
        deviceName: String,
        appVersion: String? = nil,
        bundleId: String? = nil
    ) {
        self.role = role
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.bundleId = bundleId
    }

    enum CodingKeys: String, CodingKey {
        case role
        case deviceId = "device_id"
        case deviceName = "device_name"
        case appVersion = "app_version"
        case bundleId = "bundle_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(SenderRole.self, forKey: .role) ?? .unknown
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
        bundleId = try container.decodeIfPresent(String.self, forKey: .bundleId)
    }
}

enum DeviceIdentity {
    private static let storageKey = "chat4000.device-id"

    static var currentSender: SenderInfo {
        SenderInfo(
            role: .app,
            deviceId: currentDeviceId,
            deviceName: currentDeviceName,
            appVersion: AppRegistrationIdentity.currentAppVersion,
            bundleId: AppRegistrationIdentity.currentAppId
        )
    }

    static var currentDeviceId: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: storageKey), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: storageKey)
        return created
    }

    static var currentDeviceName: String {
        #if os(iOS)
        return "iPhone"
        #elseif os(macOS)
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }
}

/// Inner message — the JSON that gets encrypted inside a `msg` envelope.
struct InnerMessage: Codable {
    let t: InnerMessageType
    let id: String
    let from: SenderInfo?
    let body: InnerBody
    let ts: Int64

    /// Create a text message (app → plugin).
    static func text(_ text: String) -> InnerMessage {
        InnerMessage(
            t: .text,
            id: UUID().uuidString,
            from: DeviceIdentity.currentSender,
            body: .text(InnerBody.TextBody(text: text)),
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    static func image(dataBase64: String, mimeType: String) -> InnerMessage {
        InnerMessage(
            t: .image,
            id: UUID().uuidString,
            from: DeviceIdentity.currentSender,
            body: .image(InnerBody.ImageBody(dataBase64: dataBase64, mimeType: mimeType)),
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    static func audio(dataBase64: String, mimeType: String, durationMs: Int, waveform: [Float]) -> InnerMessage {
        InnerMessage(
            t: .audio,
            id: UUID().uuidString,
            from: DeviceIdentity.currentSender,
            body: .audio(InnerBody.AudioBody(
                dataBase64: dataBase64,
                mimeType: mimeType,
                durationMs: durationMs,
                waveform: waveform
            )),
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    static func status(_ status: String) -> InnerMessage {
        InnerMessage(
            t: .status,
            id: UUID().uuidString,
            from: DeviceIdentity.currentSender,
            body: .status(InnerBody.StatusBody(status: status)),
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// Per protocol §6.6.5 — emit an end-to-end "I received and decoded your
    /// message" ack. The `refs` field is the inner `id` of the message being
    /// acknowledged. `stage` defaults to `.received`.
    static func ack(refs: String, stage: InnerAckStage = .received) -> InnerMessage {
        InnerMessage(
            t: .ack,
            id: UUID().uuidString,
            from: DeviceIdentity.currentSender,
            body: .ack(InnerBody.AckBody(refs: refs, stage: stage)),
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// Per protocol §6.4.2 — streaming text increment. Each frame gets a
    /// fresh `inner.id` (UUID v4); the stable stream correlator lives in
    /// `body.stream_id`.
    static func textDelta(streamId: String, delta: String) -> InnerMessage {
        InnerMessage(
            t: .textDelta,
            id: UUID().uuidString,
            from: DeviceIdentity.currentSender,
            body: .textDelta(InnerBody.TextDeltaBody(delta: delta, streamId: streamId)),
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    /// Per protocol §6.4.2 — streaming text finalizer. Each frame gets a
    /// fresh `inner.id` (UUID v4); the stable stream correlator lives in
    /// `body.stream_id`. `reset == true` abandons the stream instead of
    /// finalising it.
    static func textEnd(streamId: String, text: String, reset: Bool? = nil) -> InnerMessage {
        InnerMessage(
            t: .textEnd,
            id: UUID().uuidString,
            from: DeviceIdentity.currentSender,
            body: .textEnd(InnerBody.TextBody(text: text, reset: reset, streamId: streamId)),
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }
}

/// Type-safe inner message body.
enum InnerBody: Codable {
    case text(TextBody)
    case image(ImageBody)
    case audio(AudioBody)
    case textDelta(TextDeltaBody)
    case textEnd(TextBody)
    case status(StatusBody)
    case ack(AckBody)

    struct AckBody: Codable {
        let refs: String
        let stage: InnerAckStage
    }

    struct TextBody: Codable {
        let text: String
        let reset: Bool?
        /// Per §6.4.2: stream correlator on `text_end`. nil for plain `text`
        /// frames. Optional on decode for transitional compat with senders
        /// that still reuse `inner.id == stream_id`.
        let streamId: String?

        init(text: String, reset: Bool? = nil, streamId: String? = nil) {
            self.text = text
            self.reset = reset
            self.streamId = streamId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            reset = try container.decodeIfPresent(Bool.self, forKey: .reset)
            streamId = try container.decodeIfPresent(String.self, forKey: .streamId)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(reset, forKey: .reset)
            try container.encodeIfPresent(streamId, forKey: .streamId)
        }

        enum CodingKeys: String, CodingKey {
            case text, reset
            case streamId = "stream_id"
        }
    }

    struct TextDeltaBody: Codable {
        let delta: String
        /// Per §6.4.2: stream correlator. Optional on decode for transitional
        /// compat with senders that still reuse `inner.id == stream_id`.
        let streamId: String?

        init(delta: String, streamId: String? = nil) {
            self.delta = delta
            self.streamId = streamId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            delta = try container.decode(String.self, forKey: .delta)
            streamId = try container.decodeIfPresent(String.self, forKey: .streamId)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(delta, forKey: .delta)
            try container.encodeIfPresent(streamId, forKey: .streamId)
        }

        enum CodingKeys: String, CodingKey {
            case delta
            case streamId = "stream_id"
        }
    }

    struct ImageBody: Codable {
        let dataBase64: String
        let mimeType: String

        enum CodingKeys: String, CodingKey {
            case dataBase64 = "data_base64"
            case mimeType = "mime_type"
        }
    }

    struct AudioBody: Codable {
        let dataBase64: String
        let mimeType: String
        let durationMs: Int
        let waveform: [Float]

        enum CodingKeys: String, CodingKey {
            case dataBase64 = "data_base64"
            case mimeType = "mime_type"
            case durationMs = "duration_ms"
            case waveform
        }
    }

    struct StatusBody: Codable {
        let status: String // "thinking", "typing", "idle"
    }

    // InnerBody is not directly Decodable — InnerMessage handles dispatch via the `t` field.
    // This stub satisfies the Codable conformance; actual decoding uses InnerMessage.init(from:).
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(TextDeltaBody.self) {
            self = .textDelta(b)
        } else if let b = try? container.decode(AudioBody.self) {
            self = .audio(b)
        } else if let b = try? container.decode(ImageBody.self) {
            self = .image(b)
        } else if let b = try? container.decode(AckBody.self) {
            self = .ack(b)
        } else if let b = try? container.decode(StatusBody.self) {
            self = .status(b)
        } else if let b = try? container.decode(TextBody.self) {
            self = .text(b)
        } else {
            throw DecodingError.typeMismatch(
                InnerBody.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Cannot decode InnerBody without type context")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let b): try container.encode(b)
        case .image(let b): try container.encode(b)
        case .audio(let b): try container.encode(b)
        case .textDelta(let b): try container.encode(b)
        case .textEnd(let b): try container.encode(b)
        case .status(let b): try container.encode(b)
        case .ack(let b): try container.encode(b)
        }
    }
}

// Custom Codable for InnerMessage to handle the type-discriminated body
extension InnerMessage {

    enum CodingKeys: String, CodingKey {
        case t, id, from, body, ts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        t = try container.decode(InnerMessageType.self, forKey: .t)
        id = try container.decode(String.self, forKey: .id)
        from = try container.decodeIfPresent(SenderInfo.self, forKey: .from)
        ts = try container.decode(Int64.self, forKey: .ts)

        switch t {
        case .text:
            body = .text(try container.decode(InnerBody.TextBody.self, forKey: .body))
        case .image:
            body = .image(try container.decode(InnerBody.ImageBody.self, forKey: .body))
        case .audio:
            body = .audio(try container.decode(InnerBody.AudioBody.self, forKey: .body))
        case .textDelta:
            body = .textDelta(try container.decode(InnerBody.TextDeltaBody.self, forKey: .body))
        case .textEnd:
            body = .textEnd(try container.decode(InnerBody.TextBody.self, forKey: .body))
        case .status:
            body = .status(try container.decode(InnerBody.StatusBody.self, forKey: .body))
        case .ack:
            body = .ack(try container.decode(InnerBody.AckBody.self, forKey: .body))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(t, forKey: .t)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(from, forKey: .from)
        try container.encode(ts, forKey: .ts)
        switch body {
        case .text(let b): try container.encode(b, forKey: .body)
        case .image(let b): try container.encode(b, forKey: .body)
        case .audio(let b): try container.encode(b, forKey: .body)
        case .textDelta(let b): try container.encode(b, forKey: .body)
        case .textEnd(let b): try container.encode(b, forKey: .body)
        case .status(let b): try container.encode(b, forKey: .body)
        case .ack(let b): try container.encode(b, forKey: .body)
        }
    }
}
