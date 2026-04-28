import Foundation
import SwiftData

enum MessageSender: String, Codable {
    case user
    case agent
}

enum MessageStatus: String, Codable {
    case sending
    case sent
    case failed
}

@Model
final class ChatMessage {
    var id: UUID
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
