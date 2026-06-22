import CryptoKit
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Inner Message Types (plaintext inside encrypted msg)

/// Type discriminator for inner messages (inside the encrypted blob).
enum InnerMessageType: String, Codable {
    case text
    case image
    case audio
    case textDelta = "text_delta"
    case textEnd = "text_end"
    case status
    /// End-to-end "I received and decoded your message" ack (per section 6.6.5).
    /// Drives the "✓✓ delivered" tick. Travels inside the encrypted envelope
    /// so the relay cannot forge it.
    case ack
    /// Tool-call streaming (Hermes-specific, additive on protocol v1).
    /// `tool_id` is the stable correlator across start/delta/end. Each
    /// wire frame gets a fresh inner.id per section 6.4.2. Receivers dedupe by
    /// inner.id (section 6.6.9) and merge by tool_id.
    case toolStart = "tool_start"
    case toolDelta = "tool_delta"
    case toolEnd = "tool_end"
}

/// Status of a tool invocation reported in `tool_end.body.status`.
enum InnerToolStatus: String, Codable {
    case running
    case done
    case failed
}

/// Acknowledgement stage values per section 6.6.5. `received` is the only required
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
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            bundleId: Bundle.main.bundleIdentifier
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

    /// Per protocol section 6.6.5 — emit an end-to-end "I received and decoded your
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

    /// Per protocol section 6.4.2 — streaming text increment. Each frame gets a
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

    /// Per protocol section 6.4.2 — streaming text finalizer. Each frame gets a
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
    case toolStart(ToolStartBody)
    case toolDelta(ToolDeltaBody)
    case toolEnd(ToolEndBody)

    struct AckBody: Codable {
        let refs: String
        let stage: InnerAckStage
    }

    /// Body for `tool_start`. Args is a JSON string — may be truncated by
    /// the plugin to ~2KB to keep wire frames small.
    struct ToolStartBody: Codable {
        let toolId: String
        let name: String
        let args: String
        /// Per-tool emoji from Hermes' central registry
        /// (`agent.display.get_tool_emoji`). Nil/empty → bubble falls back
        /// to the default hammer glyph. Chat4000 inherits the same icon
        /// vocabulary as Telegram, IRC, and the CLI this way.
        let icon: String?

        enum CodingKeys: String, CodingKey {
            case toolId = "tool_id"
            case name, args, icon
        }
    }

    /// Body for `tool_delta` — streamed intermediate output (stdout etc).
    /// Coalesced by the plugin to ~256 char / 100 ms frames.
    struct ToolDeltaBody: Codable {
        let toolId: String
        let delta: String

        enum CodingKeys: String, CodingKey {
            case toolId = "tool_id"
            case delta
        }
    }

    /// Body for `tool_end`. `result` is a short summary (~4KB truncation
    /// cap on the plugin side) suitable for inline render.
    struct ToolEndBody: Codable {
        let toolId: String
        let status: InnerToolStatus
        let result: String
        let durationMs: Int

        enum CodingKeys: String, CodingKey {
            case toolId = "tool_id"
            case status, result
            case durationMs = "duration_ms"
        }
    }

    struct TextBody: Codable {
        let text: String
        let reset: Bool?
        /// Per section 6.4.2: stream correlator on `text_end`. nil for plain `text`
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

        // EXEMPT: Codable `encode(to:)` is a protocol requirement that mandates untyped `throws`.
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
        /// Per section 6.4.2: stream correlator. Optional on decode for transitional
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

        // EXEMPT: Codable `encode(to:)` is a protocol requirement that mandates untyped `throws`.
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
        if let b = try? container.decode(ToolStartBody.self) {
            self = .toolStart(b)
        } else if let b = try? container.decode(ToolDeltaBody.self) {
            self = .toolDelta(b)
        } else if let b = try? container.decode(ToolEndBody.self) {
            self = .toolEnd(b)
        } else if let b = try? container.decode(TextDeltaBody.self) {
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

    // EXEMPT: Codable `encode(to:)` is a protocol requirement that mandates untyped `throws`.
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
        case .toolStart(let b): try container.encode(b)
        case .toolDelta(let b): try container.encode(b)
        case .toolEnd(let b): try container.encode(b)
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
        case .toolStart:
            body = .toolStart(try container.decode(InnerBody.ToolStartBody.self, forKey: .body))
        case .toolDelta:
            body = .toolDelta(try container.decode(InnerBody.ToolDeltaBody.self, forKey: .body))
        case .toolEnd:
            body = .toolEnd(try container.decode(InnerBody.ToolEndBody.self, forKey: .body))
        }
    }

    // EXEMPT: Codable `encode(to:)` is a protocol requirement that mandates untyped `throws`.
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
        case .toolStart(let b): try container.encode(b, forKey: .body)
        case .toolDelta(let b): try container.encode(b, forKey: .body)
        case .toolEnd(let b): try container.encode(b, forKey: .body)
        }
    }
}
