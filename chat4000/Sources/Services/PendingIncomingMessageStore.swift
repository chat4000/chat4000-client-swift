import Foundation

struct PendingIncomingMessage: Codable {
    enum Payload: Codable {
        case text(String)
        case image(dataBase64: String)
        case audio(dataBase64: String, mimeType: String, durationMs: Int, waveform: [Float])
    }

    let dedupeKey: String
    let messageId: String
    let payload: Payload
    let receivedAt: Date
}

private struct PendingIncomingEnvelope: Codable {
    var messages: [PendingIncomingMessage]
    var notifiedKeys: [String]
}

actor PendingIncomingMessageStore {
    static let shared = PendingIncomingMessageStore()

    private let maxNotifiedKeys = 256

    private var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("chat4000", isDirectory: true)
            .appendingPathComponent(AppEnvironment.current.storageNamespace, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending-incoming-messages.json")
    }

    @discardableResult
    func enqueue(_ message: PendingIncomingMessage) -> Bool {
        var envelope = loadEnvelope()

        if envelope.messages.contains(where: { $0.dedupeKey == message.dedupeKey }) {
            DevLog.log("📬 pending enqueue skipped duplicate key=%@", message.dedupeKey)
            return false
        }

        envelope.messages.append(message)
        saveEnvelope(envelope)
        DevLog.log(
            "📬 pending enqueue saved key=%@ id=%@ total=%ld",
            message.dedupeKey,
            message.messageId,
            envelope.messages.count
        )
        return true
    }

    func drain() -> [PendingIncomingMessage] {
        var envelope = loadEnvelope()
        let drained = envelope.messages.sorted { $0.receivedAt < $1.receivedAt }
        envelope.messages.removeAll()
        saveEnvelope(envelope)
        DevLog.log("📬 pending drain count=%ld", drained.count)
        return drained
    }

    @discardableResult
    func markNotificationSent(for key: String) -> Bool {
        var envelope = loadEnvelope()
        if envelope.notifiedKeys.contains(key) {
            DevLog.log("🔔 [push] notification dedupe hit key=%@", key)
            return false
        }

        envelope.notifiedKeys.append(key)
        if envelope.notifiedKeys.count > maxNotifiedKeys {
            envelope.notifiedKeys.removeFirst(envelope.notifiedKeys.count - maxNotifiedKeys)
        }
        saveEnvelope(envelope)
        DevLog.log("🔔 [push] notification dedupe stored key=%@ total=%ld", key, envelope.notifiedKeys.count)
        return true
    }

    private func loadEnvelope() -> PendingIncomingEnvelope {
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(PendingIncomingEnvelope.self, from: data)
        else {
            return PendingIncomingEnvelope(messages: [], notifiedKeys: [])
        }
        return envelope
    }

    private func saveEnvelope(_ envelope: PendingIncomingEnvelope) {
        guard let data = try? JSONEncoder().encode(envelope) else {
            DevLog.log("ERROR: Failed to encode pending incoming envelope")
            return
        }

        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            DevLog.log("ERROR: Failed to persist pending incoming envelope: %@", error.localizedDescription)
        }
    }
}
