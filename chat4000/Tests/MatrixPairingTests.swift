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
}
