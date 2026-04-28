import Foundation
import Testing
@testable import chat94

struct InnerMessageTests {
    private let sender = SenderInfo(role: .app, deviceId: "device-1", deviceName: "Test iPhone")

    @Test
    func encodeDecodeRoundTripForAllInnerTypes() throws {
        let messages: [InnerMessage] = [
            InnerMessage(t: .text, id: "1", from: sender, body: .text(.init(text: "hello")), ts: 1),
            InnerMessage(t: .image, id: "2", from: sender, body: .image(.init(dataBase64: "aGVsbG8=", mimeType: "image/jpeg")), ts: 2),
            InnerMessage(t: .audio, id: "3", from: sender, body: .audio(.init(dataBase64: "YXVkaW8=", mimeType: "audio/mp4", durationMs: 1200, waveform: [0.1, 0.5, 0.9])), ts: 3),
            InnerMessage(t: .textDelta, id: "4", from: sender, body: .textDelta(.init(delta: "he")), ts: 4),
            InnerMessage(t: .textEnd, id: "5", from: sender, body: .textEnd(.init(text: "hello")), ts: 5),
            InnerMessage(t: .status, id: "6", from: sender, body: .status(.init(status: "thinking")), ts: 6),
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for message in messages {
            let data = try encoder.encode(message)
            let decoded = try decoder.decode(InnerMessage.self, from: data)
            #expect(decoded.t == message.t)
            #expect(decoded.id == message.id)
            #expect(decoded.from == message.from)
            #expect(decoded.ts == message.ts)
            #expect(bodyDescription(decoded.body) == bodyDescription(message.body))
        }
    }

    @Test
    func textFactoryProducesExpectedStructure() {
        let message = InnerMessage.text("hello")
        #expect(message.t == .text)
        #expect(!message.id.isEmpty)
        #expect(message.from?.role == .app)
        #expect(!(message.from?.deviceId.isEmpty ?? true))
        #expect(!(message.from?.deviceName.isEmpty ?? true))
        #expect(message.ts > 0)

        guard case .text(let body) = message.body else {
            Issue.record("Expected .text body")
            return
        }

        #expect(body.text == "hello")
    }

    @Test
    func audioFactoryProducesExpectedStructure() {
        let message = InnerMessage.audio(
            dataBase64: "YXVkaW8=",
            mimeType: "audio/mp4",
            durationMs: 1500,
            waveform: [0.2, 0.6]
        )

        #expect(message.t == .audio)
        #expect(!message.id.isEmpty)
        #expect(message.from?.role == .app)
        #expect(message.ts > 0)

        guard case .audio(let body) = message.body else {
            Issue.record("Expected .audio body")
            return
        }

        #expect(body.dataBase64 == "YXVkaW8=")
        #expect(body.mimeType == "audio/mp4")
        #expect(body.durationMs == 1500)
        #expect(body.waveform == [0.2, 0.6])
    }

    @Test
    func textEndDecodesResetTrue() throws {
        let json = #"{"t":"text_end","id":"stream-1","ts":1,"body":{"text":"hi","reset":true}}"#
        let data = try #require(json.data(using: .utf8))
        let inner = try JSONDecoder().decode(InnerMessage.self, from: data)
        guard case .textEnd(let body) = inner.body else {
            Issue.record("Expected .textEnd body")
            return
        }
        #expect(body.text == "hi")
        #expect(body.reset == true)
    }

    @Test
    func textEndDecodesResetFalseAndAbsent() throws {
        let absentJSON = #"{"t":"text_end","id":"stream-2","ts":2,"body":{"text":"hi"}}"#
        let absent = try JSONDecoder().decode(InnerMessage.self, from: try #require(absentJSON.data(using: .utf8)))
        guard case .textEnd(let absentBody) = absent.body else {
            Issue.record("Expected .textEnd body")
            return
        }
        #expect(absentBody.reset == nil)

        let falseJSON = #"{"t":"text_end","id":"stream-3","ts":3,"body":{"text":"hi","reset":false}}"#
        let falseInner = try JSONDecoder().decode(InnerMessage.self, from: try #require(falseJSON.data(using: .utf8)))
        guard case .textEnd(let falseBody) = falseInner.body else {
            Issue.record("Expected .textEnd body")
            return
        }
        #expect(falseBody.reset == false)
    }

    @Test
    func textBodyEncodingOmitsResetWhenNil() throws {
        let body = InnerBody.TextBody(text: "hi")
        let data = try JSONEncoder().encode(body)
        let str = try #require(String(data: data, encoding: .utf8))
        #expect(!str.contains("reset"))
    }

    @Test
    func statusFactoryProducesExpectedStructure() {
        let message = InnerMessage.status("typing")

        #expect(message.t == .status)
        #expect(!message.id.isEmpty)
        #expect(message.from?.role == .app)
        #expect(message.ts > 0)

        guard case .status(let body) = message.body else {
            Issue.record("Expected .status body")
            return
        }

        #expect(body.status == "typing")
    }

    private func bodyDescription(_ body: InnerBody) -> String {
        switch body {
        case .text(let value):
            return "text:\(value.text)"
        case .image(let value):
            return "image:\(value.mimeType):\(value.dataBase64)"
        case .audio(let value):
            return "audio:\(value.mimeType):\(value.durationMs):\(value.waveform.map { String($0) }.joined(separator: ","))"
        case .textDelta(let value):
            return "textDelta:\(value.delta)"
        case .textEnd(let value):
            return "textEnd:\(value.text)"
        case .status(let value):
            return "status:\(value.status)"
        }
    }
}
