import Foundation
import SwiftData

enum MessageSender: String, Codable {
    case user
    case agent
}

enum MessageStatus: String, Codable {
    case sending
    case sent
    case delivered
    case failed
}

/// Distinguishes ordinary text/image/audio rows from Hermes tool-call rows.
/// Additive — pre-existing persisted rows decode as `.message`.
enum MessageKind: String, Codable {
    case message
    case toolCall = "tool_call"
}

/// Lifecycle of a Hermes tool-call row (mirrors the wire `tool_status`
/// field on the closing `tool_end` frame).
enum ToolCallStatus: String, Codable {
    case running
    case done
    case failed
}

@Model
final class ChatMessage {
    var id: UUID
    /// Relay-protocol inner message id (per protocol §6.4.1 + §6.6.9). Used
    /// for idempotent insert (dedupe on relay redrive) and to correlate
    /// `relay_recv_ack` / inner `ack` frames back to local outbound rows.
    /// Nullable for backwards compatibility with rows persisted before the
    /// ack layer landed; new rows always set this.
    var msgId: String?
    var text: String
    var imageData: Data?
    var audioData: Data?
    var audioMimeType: String?
    var audioDuration: Double?
    var audioWaveformData: Data?
    var sender: MessageSender
    var timestamp: Date
    var status: MessageStatus

    // MARK: - Hermes tool-call fields
    //
    // All optional / nilable so they remain additive against persisted
    // SwiftData rows that were written before the Hermes commit landed.
    // For ordinary `.message` rows these stay nil.

    /// Backing storage for `kind`. Optional so SwiftData can read pre-
    /// existing rows that were persisted before this column existed — those
    /// decode as nil and the computed `kind` falls back to `.message`.
    /// Do not access directly outside this file.
    private var kindRaw: String?

    /// Discriminates the row's UI rendering path. Backed by `kindRaw` for
    /// migration safety; defaults to `.message` for pre-existing rows.
    var kind: MessageKind {
        get { kindRaw.flatMap { MessageKind(rawValue: $0) } ?? .message }
        set { kindRaw = newValue.rawValue }
    }

    /// Stable correlator across all `tool_start` / `tool_delta` / `tool_end`
    /// frames for one tool invocation (per protocol §6.4.x).
    var toolId: String?

    /// Short tool identifier emitted by the Hermes agent (e.g. `"bash"`,
    /// `"web.search"`, `"read_file"`).
    var toolName: String?

    /// JSON-stringified arguments the tool was invoked with. Plugin-side
    /// truncated to roughly 2 KB; the renderer assumes safe lengths.
    var toolArgs: String?

    /// Short result summary returned by the tool. Plugin-side truncated to
    /// roughly 4 KB. Nil while the tool is still running.
    var toolResult: String?

    /// Lifecycle state. Starts as `.running` on `tool_start` and is flipped
    /// to `.done` / `.failed` when the closing `tool_end` arrives.
    var toolStatus: ToolCallStatus?

    /// Wall-clock duration in milliseconds for completed tools, set from
    /// the `tool_end` frame. Nil while running.
    var toolDurationMs: Int?

    /// Per-tool emoji from Hermes' `agent.display.get_tool_emoji` registry
    /// (`skill_view → 📚`, `todo → 📋`, `cronjob → ⏰`, …). Nil/empty →
    /// bubble uses its default hammer glyph.
    var toolIcon: String?

    init(
        id: UUID = UUID(),
        msgId: String? = nil,
        text: String = "",
        imageData: Data? = nil,
        audioData: Data? = nil,
        audioMimeType: String? = nil,
        audioDuration: Double? = nil,
        audioWaveform: [Float]? = nil,
        sender: MessageSender,
        timestamp: Date = .now,
        status: MessageStatus = .sent,
        kind: MessageKind = .message,
        toolId: String? = nil,
        toolName: String? = nil,
        toolArgs: String? = nil,
        toolResult: String? = nil,
        toolStatus: ToolCallStatus? = nil,
        toolDurationMs: Int? = nil,
        toolIcon: String? = nil
    ) {
        self.id = id
        // Default new rows to use the local UUID as the msg_id when no
        // protocol-side id was assigned. This keeps every row addressable by
        // a string id without breaking existing call sites.
        self.msgId = msgId ?? id.uuidString
        self.text = text
        self.imageData = imageData
        self.audioData = audioData
        self.audioMimeType = audioMimeType
        self.audioDuration = audioDuration
        self.audioWaveformData = audioWaveform != nil ? VoiceWaveformCodec.encode(audioWaveform ?? []) : nil
        self.sender = sender
        self.timestamp = timestamp
        self.status = status
        self.kindRaw = kind.rawValue
        self.toolId = toolId
        self.toolName = toolName
        self.toolArgs = toolArgs
        self.toolResult = toolResult
        self.toolStatus = toolStatus
        self.toolDurationMs = toolDurationMs
        self.toolIcon = toolIcon
    }
}

extension ChatMessage {
    var audioWaveform: [Float] {
        VoiceWaveformCodec.decode(audioWaveformData) ?? Array(repeating: 0.12, count: VoiceNoteConstants.waveformSampleCount)
    }
}
