import Foundation
import Testing
@testable import chat4000

struct MatrixMediaTests {
    /// Worth 9 — if AES-CTR / IV / key encoding is wrong, every encrypted
    /// attachment is silently corrupt (sends garbage, fails to open on receipt).
    @Test
    func cryptoRoundtripRecoversPlaintext() throws {
        // A few sizes incl. non-block-aligned and empty.
        for size in [0, 1, 15, 16, 17, 1024, 70_000] {
            var bytes = [UInt8](repeating: 0, count: size)
            for i in 0..<size { bytes[i] = UInt8(i % 251) }
            let plaintext = Data(bytes)
            let recovered = try #require(MatrixMedia.cryptoRoundtripForTesting(plaintext))
            #expect(recovered == plaintext)
        }
    }

    /// Worth 7 — the EncryptedFile parser must reject malformed input (missing
    /// key/url) rather than crash or silently produce a broken decrypt.
    @Test
    func encryptedFileRejectsMalformed() {
        #expect(MatrixMedia.EncryptedFile(["iv": "x"]) == nil)
        #expect(MatrixMedia.EncryptedFile(["url": "mxc://s/m"]) == nil) // no key
        #expect(MatrixMedia.EncryptedFile([
            "url": "mxc://s/m", "key": ["k": "AAA"], "iv": "BBB",
        ]) != nil)
    }
}
