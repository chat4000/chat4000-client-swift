import Foundation
import Testing
@testable import chat4000

struct CryptoTests {
    @Test
    func encryptDecryptRoundTrip() throws {
        let key = Data((0..<32).map(UInt8.init))
        let plaintext = Data("hello relay".utf8)

        let encrypted = try #require(RelayCrypto.encrypt(plaintext: plaintext, key: key))
        #expect(Data(base64Encoded: encrypted.nonce)?.count == 24)
        #expect(Data(base64Encoded: encrypted.ciphertext)?.count == plaintext.count + 16)

        let decrypted = RelayCrypto.decrypt(
            nonceBase64: encrypted.nonce,
            ciphertextBase64: encrypted.ciphertext,
            key: key
        )

        #expect(decrypted == plaintext)
    }

    @Test
    func derivesPairIdFromKnownVector() {
        let key = Data((0..<32).map(UInt8.init))
        let groupId = RelayCrypto.deriveGroupId(from: key)
        #expect(groupId == "630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd")
    }

    @Test
    func supportsEmptyPayload() throws {
        let key = Data(repeating: 9, count: 32)
        let encrypted = try #require(RelayCrypto.encrypt(plaintext: Data(), key: key))

        let decrypted = RelayCrypto.decrypt(
            nonceBase64: encrypted.nonce,
            ciphertextBase64: encrypted.ciphertext,
            key: key
        )

        #expect(decrypted == Data())
    }

    @Test
    func supportsMaxSizePayload() throws {
        let key = Data(repeating: 11, count: 32)
        let plaintext = Data((0..<RelayProtocol.maxMessageSize).map { UInt8($0 % 251) })

        let encrypted = try #require(RelayCrypto.encrypt(plaintext: plaintext, key: key))
        let decrypted = RelayCrypto.decrypt(
            nonceBase64: encrypted.nonce,
            ciphertextBase64: encrypted.ciphertext,
            key: key
        )

        #expect(decrypted == plaintext)
    }

    @Test
    func corruptedCiphertextFails() throws {
        let key = Data(repeating: 3, count: 32)
        let encrypted = try #require(RelayCrypto.encrypt(plaintext: Data("payload".utf8), key: key))
        var ciphertext = try #require(Data(base64Encoded: encrypted.ciphertext))
        ciphertext[ciphertext.startIndex] ^= 0x01

        let decrypted = RelayCrypto.decrypt(
            nonceBase64: encrypted.nonce,
            ciphertextBase64: ciphertext.base64EncodedString(),
            key: key
        )

        #expect(decrypted == nil)
    }

    @Test
    func wrongKeyFails() throws {
        let key = Data(repeating: 5, count: 32)
        let wrongKey = Data(repeating: 6, count: 32)
        let encrypted = try #require(RelayCrypto.encrypt(plaintext: Data("payload".utf8), key: key))

        let decrypted = RelayCrypto.decrypt(
            nonceBase64: encrypted.nonce,
            ciphertextBase64: encrypted.ciphertext,
            key: wrongKey
        )

        #expect(decrypted == nil)
    }
}
