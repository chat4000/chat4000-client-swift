import Foundation
import Testing
import MatrixRustSDK
@testable import chat4000

struct MatrixCredentialStoreTests {
    private func makeSession(
        token: String = "tok",
        refresh: String? = "ref",
        user: String = "@u:x",
        device: String = "DEV"
    ) -> Session {
        Session(
            accessToken: token,
            refreshToken: refresh,
            userId: user,
            deviceId: device,
            homeserverUrl: "https://matrix.example",
            oauthData: nil,
            slidingSyncVersion: .native
        )
    }

    /// Worth 8 — corrupt persistence = user silently logged out on relaunch.
    @Test
    func storedCodableRoundtripPreservesFields() throws {
        let stored = MatrixCredentialStore.Stored(session: makeSession(), storePassphrase: "pass123")
        let data = try JSONEncoder().encode(stored)
        let back = try JSONDecoder().decode(MatrixCredentialStore.Stored.self, from: data)

        #expect(back.accessToken == "tok")
        #expect(back.refreshToken == "ref")
        #expect(back.userId == "@u:x")
        #expect(back.deviceId == "DEV")
        #expect(back.homeserverUrl == "https://matrix.example")
        #expect(back.storePassphrase == "pass123")
        // Conversion back to an SDK Session must use native sliding sync.
        #expect(back.session.slidingSyncVersion == .native)
    }

    /// Worth 8 — security-critical: a token refresh must keep the store
    /// passphrase and not drop the rotated token.
    @Test
    func delegateRefreshKeepsPassphraseAndUpdatesTokens() throws {
        let seed = MatrixCredentialStore.Stored(
            session: makeSession(token: "old", refresh: "oldref"),
            storePassphrase: "keepme"
        )
        try MatrixCredentialStore.save(seed)
        defer { MatrixCredentialStore.delete() }

        MatrixSessionDelegate().saveSessionInKeychain(session: makeSession(token: "new", refresh: "newref"))

        let loaded = try #require(MatrixCredentialStore.load())
        #expect(loaded.accessToken == "new")
        #expect(loaded.refreshToken == "newref")
        #expect(loaded.storePassphrase == "keepme")
    }
}
