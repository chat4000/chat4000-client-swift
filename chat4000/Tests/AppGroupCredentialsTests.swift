import Foundation
import Testing
@testable import chat4000

// F2 (protocol F.2.1 / F.2.3 / F.2.4): pure-logic tests for the App-Group /
// shared-credential plumbing. The keychain + container I/O is environment-bound
// and exercised on-device, not here; these cover the deterministic derivations.

struct AppGroupCredentialsTests {
    /// Worth 8 — `account_id` is the pusher↔keychain join key (F). If it isn't
    /// stable + deterministic, the NSE resolves the wrong (or no) credentials.
    @Test
    func accountIdIsDeterministicUserPipeDevice() {
        let id = SharedCredentials.accountId(userId: "@u_abc:chat4000.com", deviceId: "DEV123")
        #expect(id == "@u_abc:chat4000.com|DEV123")
        // Same inputs → same id (no randomness).
        #expect(id == SharedCredentials.accountId(userId: "@u_abc:chat4000.com", deviceId: "DEV123"))
        // Different device → different id (so two devices never collide).
        #expect(id != SharedCredentials.accountId(userId: "@u_abc:chat4000.com", deviceId: "DEV999"))
    }

    /// Worth 7 — the App-Group identifier must be derived from the running bundle
    /// id with the NSE `.nse` suffix stripped (F.2.4), so a NSE lands in its app's
    /// group. We can't change `Bundle.main` in a unit test, but we CAN assert the
    /// identifier is well-formed (group-prefixed) for whatever flavor hosts it.
    @Test
    func appGroupIdentifierIsGroupPrefixed() {
        #expect(AppGroup.identifier.hasPrefix("group.com.neonnode.chat94app"))
        // Lockfile + generation URLs (when a container exists) sit in the crypto
        // dir and are NOT the sqlite files themselves (F.2.3). When there is no
        // container in the test host, they are nil — both consistently.
        let ns = AppEnvironment.current.storageNamespace
        let lock = AppGroup.lockfileURL(namespace: ns)
        let gen = AppGroup.generationURL(namespace: ns)
        #expect((lock == nil) == (gen == nil))
        if let lock, let gen {
            #expect(lock.lastPathComponent == "crypto-store.lock")
            #expect(gen.lastPathComponent == "crypto-store.generation")
            #expect(lock.pathExtension != "sqlite")
        }
    }

    /// Worth 7 — the shared keychain access group is the bare group string
    /// (SecItem matches without the team prefix), and is the SAME across flavors
    /// so the dev and App Store apps can share one credential item.
    @Test
    func keychainAccessGroupIsSharedConstant() {
        #expect(SharedCredentials.accountId(userId: "@u:x", deviceId: "d").isEmpty == false)
        #expect(AppGroup.keychainAccessGroup == "com.neonnode.chat94app.shared")
    }

    /// Worth 8 — the NSE round-trips a `Record` through JSON (keychain payload);
    /// a codec regression silently breaks the NSE's credential read → every push
    /// falls back to the generic banner.
    @Test
    func sharedCredentialRecordCodableRoundtrip() throws {
        let record = SharedCredentials.Record(
            accessToken: "tok",
            userId: "@u:x",
            deviceId: "DEV",
            gatewayURL: "wss://gateway.example/ws",
            cryptoStorePath: "/tmp/store"
        )
        let data = try JSONEncoder().encode(record)
        let back = try JSONDecoder().decode(SharedCredentials.Record.self, from: data)
        #expect(back == record)
    }
}
