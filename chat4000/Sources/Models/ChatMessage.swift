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
        status: MessageStatus = .sent
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
    }
}

extension ChatMessage {
    var audioWaveform: [Float] {
        VoiceWaveformCodec.decode(audioWaveformData) ?? Array(repeating: 0.12, count: VoiceNoteConstants.waveformSampleCount)
    }
}
