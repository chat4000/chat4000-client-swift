import Foundation
import Testing
@testable import chat4000

struct MatrixCredentialStoreTests {
    private func makeStored(
        token: String = "tok",
        user: String = "@u:x",
        device: String = "DEV"
    ) -> MatrixCredentialStore.Stored {
        MatrixCredentialStore.Stored(
            accessToken: token,
            userId: user,
            deviceId: device,
            gatewayURL: "wss://gateway.example/ws",
            storePassphrase: "pass123"
        )
    }

    /// Worth 8 — corrupt persistence = user silently logged out on relaunch.
    @Test
    func storedCodableRoundtripPreservesFields() throws {
        let stored = makeStored()
        let data = try JSONEncoder().encode(stored)
        let back = try JSONDecoder().decode(MatrixCredentialStore.Stored.self, from: data)

        #expect(back.accessToken == "tok")
        #expect(back.userId == "@u:x")
        #expect(back.deviceId == "DEV")
        #expect(back.gatewayURL == "wss://gateway.example/ws")
        #expect(back.storePassphrase == "pass123")
    }

    /// Worth 8 — save → load must preserve credentials across a relaunch, and
    /// delete must actually clear them (a stale token = a broken session).
    @Test
    func saveLoadDeleteRoundtrip() throws {
        try MatrixCredentialStore.save(makeStored(token: "saved"))
        defer { MatrixCredentialStore.delete() }

        let loaded = try #require(MatrixCredentialStore.load())
        #expect(loaded.accessToken == "saved")
        #expect(loaded.gatewayURL == "wss://gateway.example/ws")

        MatrixCredentialStore.delete()
        #expect(MatrixCredentialStore.load() == nil)
    }

    /// Worth 5 — the store passphrase must be fresh, base64, and 32 bytes; a
    /// weak/empty passphrase silently disables crypto-store encryption at rest.
    @Test
    func newStorePassphraseIs32RandomBytes() {
        let a = MatrixCredentialStore.newStorePassphrase()
        let b = MatrixCredentialStore.newStorePassphrase()
        #expect(a != b)
        #expect(Data(base64Encoded: a)?.count == 32)
    }
}
