import CryptoKit
import Foundation
import Testing
@testable import chat94

struct PairingCryptoTests {
    @Test
    func normalizePairingCodeUppercasesAndRemovesSeparators() {
        #expect(RelayCrypto.normalizePairingCode("ab-cd efgh") == "ABCDEFGH")
    }

    @Test
    func pairingRoomIdMatchesForEquivalentCodes() {
        let first = RelayCrypto.derivePairingRoomId(from: "ABCD-EFGH")
        let second = RelayCrypto.derivePairingRoomId(from: "abcdefgh")
        #expect(first == second)
    }

    @Test
    func wrapAndUnwrapGroupKeyRoundTrips() throws {
        let groupKey = RelayCrypto.generateGroupKey()
        let joinerPrivateKey = RelayCrypto.generateJoinerPrivateKey()
        let joinerPublicKey = RelayCrypto.publicKeyData(from: joinerPrivateKey)

        let wrapped = try #require(
            RelayCrypto.wrapGroupKey(groupKey, to: joinerPublicKey)
        )

        let unwrapped = try #require(RelayCrypto.unwrapGroupKey(wrapped, joinerPrivateKey: joinerPrivateKey))

        #expect(unwrapped == groupKey)
    }

    @Test
    func pairProofUsesDelimitedEncoding() {
        let code = "ABCD-EFGH"
        let initiatorSalt = Data([0x01, 0x02, 0x03])
        let joinerPublicKey = Data([0x04, 0x05, 0x06])

        var expectedBytes = Data("ABCDEFGH".utf8)
        expectedBytes.append(0)
        expectedBytes.append(initiatorSalt)
        expectedBytes.append(0)
        expectedBytes.append(joinerPublicKey)
        expectedBytes.append(0)
        expectedBytes.append(Data("B".utf8))

        let expected = Data(SHA256.hash(data: expectedBytes)).base64EncodedString()
        let actual = RelayCrypto.derivePairProof(
            code: code,
            initiatorSalt: initiatorSalt,
            joinerPublicKey: joinerPublicKey,
            label: "B"
        )

        #expect(actual == expected)
    }

    @Test
    func parsePairingURIReadsCodeAndIgnoresRelayOverride() throws {
        let invite = try #require(
            RelayCrypto.parsePairingURI("chat94://pair?relay=wss%3A%2F%2Frelay.chat94.com%2Fws&code=EWAC-489F")
        )

        #expect(invite.code == "EWAC489F")
    }

    @Test
    func parsePairingURIRejectsInvalidCode() {
        #expect(RelayCrypto.parsePairingURI("chat94://pair?code=BAD") == nil)
    }
}
