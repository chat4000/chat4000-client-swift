import Foundation
import Testing
@testable import chat94

struct ProtocolTests {
    @Test
    func helloBuilderProducesExpectedFields() throws {
        let json = try #require(RelayOutgoing.hello(groupId: "abc123", deviceToken: "token-1"))
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])

        #expect(object["version"] as? Int == RelayProtocol.version)
        #expect(object["type"] as? String == "hello")
        #expect(payload["role"] as? String == "app")
        #expect(payload["group_id"] as? String == "abc123")
        #expect(payload["device_token"] as? String == "token-1")
    }

    @Test
    func challengeBuilderProducesExpectedEnvelope() throws {
        let json = try #require(RelayOutgoing.challenge())
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["version"] as? Int == RelayProtocol.version)
        #expect(object["type"] as? String == "challenge")
        #expect((object["payload"] as? [String: Any])?.isEmpty == true)
    }

    @Test
    func registerBuilderProducesExpectedFields() throws {
        let json = try #require(RelayOutgoing.register(groupId: "group-1", attestation: "attest-1", challenge: "nonce-1"))
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])

        #expect(object["version"] as? Int == RelayProtocol.version)
        #expect(object["type"] as? String == "register")
        #expect(payload["group_id"] as? String == "group-1")
        #expect(payload["attestation"] as? String == "attest-1")
        #expect(payload["challenge"] as? String == "nonce-1")
    }

    @Test
    func pairOpenBuilderProducesExpectedFields() throws {
        let json = try #require(RelayOutgoing.pairOpen(role: "initiator", roomId: "room-1"))
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])

        #expect(object["version"] as? Int == RelayProtocol.version)
        #expect(object["type"] as? String == "pair_open")
        #expect(payload["role"] as? String == "initiator")
        #expect(payload["room_id"] as? String == "room-1")
    }

    @Test
    func pairGrantBuilderProducesExpectedFields() throws {
        let wrappedKey = WrappedGroupKey(
            ephemeralPub: "pub-1",
            nonce: "nonce-1",
            ciphertext: "cipher-1"
        )
        let json = try #require(RelayOutgoing.pairGrant(proof: "proof-a", wrappedKey: wrappedKey))
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])
        let wrapped = try #require(payload["wrapped_key"] as? [String: Any])

        #expect(object["type"] as? String == "pair_data")
        #expect(payload["t"] as? String == "grant")
        #expect(payload["proof"] as? String == "proof-a")
        #expect(wrapped["ephemeral_pub"] as? String == "pub-1")
        #expect(wrapped["nonce"] as? String == "nonce-1")
        #expect(wrapped["ciphertext"] as? String == "cipher-1")
    }

    @Test(arguments: [
        #"{"version":1,"type":"challenge_ok","payload":{"nonce":"abc","expires_in_secs":60}}"#,
        #"{"version":1,"type":"register_ok","payload":{"group_id":"group-id"}}"#,
        #"{"version":1,"type":"register_error","payload":{"code":"NOPE","message":"failed"}}"#,
        #"{"version":1,"type":"hello_ok","payload":{}}"#,
        #"{"version":1,"type":"hello_error","payload":{"code":"NOPE","message":"failed"}}"#,
        #"{"version":1,"type":"msg","payload":{"nonce":"n","ciphertext":"c","msg_id":"m"}}"#,
        #"{"version":1,"type":"pong","payload":null}"#,
        #"{"version":1,"type":"pair_open_ok","payload":{}}"#,
        #"{"version":1,"type":"pair_ready","payload":{}}"#,
        #"{"version":1,"type":"pair_data","payload":{"t":"hello","salt":"a"}}"#,
        #"{"version":1,"type":"pair_data","payload":{"t":"join","salt":"b"}}"#,
        #"{"version":1,"type":"pair_data","payload":{"t":"proof_b","proof":"c"}}"#,
        #"{"version":1,"type":"pair_data","payload":{"t":"grant","proof":"d","wrapped_key":{"ephemeral_pub":"e1","nonce":"e2","ciphertext":"e3"}}}"#,
        #"{"version":1,"type":"pair_complete","payload":{"status":"ok"}}"#,
        #"{"version":1,"type":"pair_cancel","payload":{}}"#
    ])
    func parsesSupportedIncomingMessages(_ json: String) {
        #expect(RelayMessage.parse(from: json) != nil)
    }

    @Test
    func unknownTypeReturnsNil() {
        let json = #"{"version":1,"type":"unknown","payload":{}}"#
        #expect(RelayMessage.parse(from: json) == nil)
    }

    @Test(arguments: [
        #"{"version":1,"type":"typing","payload":{}}"#,
        #"{"version":1,"type":"typing_stop","payload":{}}"#
    ])
    func legacyOuterTypingFramesAreIgnored(_ json: String) {
        #expect(RelayMessage.parse(from: json) == nil)
    }

    @Test
    func malformedJsonReturnsNil() {
        let json = #"{"version":1,"type":"msg","payload":{"nonce":"n""#
        #expect(RelayMessage.parse(from: json) == nil)
    }
}
