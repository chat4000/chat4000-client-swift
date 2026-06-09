import Foundation
import Testing
@testable import chat4000

struct MatrixPairingTests {
    /// Worth 9 — the exact wire contract with the registrar's `/pair/redeem`.
    /// A field rename on either side silently breaks pairing.
    @Test
    func decodesRedeemResponse() throws {
        let json = Data("""
        {
          "gateway_url": "wss://gateway.stgcht4.duckdns.org/ws",
          "user_id": "@u_abc:stgcht4.duckdns.org",
          "device_id": "DEVICE123",
          "access_token": "syt_secret_token"
        }
        """.utf8)

        let r = try JSONDecoder().decode(MatrixPairing.Credentials.self, from: json)

        #expect(r.gatewayUrl == "wss://gateway.stgcht4.duckdns.org/ws")
        #expect(r.userId == "@u_abc:stgcht4.duckdns.org")
        #expect(r.deviceId == "DEVICE123")
        #expect(r.accessToken == "syt_secret_token")
    }

    /// Worth 9 — regression: a `chat4000://pair?code=NNNNNN` QR/URI must yield
    /// the `code` param, NOT the first 6 digits of the whole string (the URI's
    /// "chat4000" contributes 4000, which produced "invalid pairing code").
    @Test
    func extractsCodeFromUriNotStrayDigits() {
        #expect(MatrixPairing.extractCode(from: "chat4000://pair?code=322144") == "322144")
        #expect(MatrixPairing.extractCode(from: "chat4000://pair?code=322144&x=1") == "322144")
        #expect(MatrixPairing.extractCode(from: "322144") == "322144")
        #expect(MatrixPairing.extractCode(from: "322 144") == "322144")
        #expect(MatrixPairing.extractCode(from: "  322144 ") == "322144")
    }

    @Test
    func parsesDevicePairStartResult() throws {
        let payload = try #require(MatrixSession.parseDevicePairingPayload([
            "msgtype": "chat4000.command_result",
            "command": "device.pair_start",
            "pair_id": "p_7af3c1",
            "code": "428913"
        ]))

        #expect(payload.kind == .startResult)
        #expect(payload.pairId == "p_7af3c1")
        #expect(payload.code == "428913")
        #expect(payload.error == nil)
    }

    @Test
    func parsesDevicePairStatusAndRejectsBadCodeShape() throws {
        let status = try #require(MatrixSession.parseDevicePairingPayload([
            "msgtype": "chat4000.pair_status",
            "pair_id": "p_7af3c1",
            "state": "completed"
        ]))
        #expect(status.kind == .status)
        #expect(status.state == "completed")

        let badStart = try #require(MatrixSession.parseDevicePairingPayload([
            "msgtype": "chat4000.command_result",
            "command": "device.pair_start",
            "pair_id": "p_7af3c1",
            "code": "1234567"
        ]))
        #expect(badStart.code == nil)
    }
}
