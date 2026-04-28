import Foundation
import Testing
@testable import chat94

struct PairConfigTests {
    private let sequentialKey = Data((0..<32).map(UInt8.init))
    private let sequentialBase64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
    private let sequentialBase64URL = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    @Test
    func initFromBase64URLKey() throws {
        let config = try #require(GroupConfig(base64URLKey: sequentialBase64URL))
        #expect(config.groupKey == sequentialKey)
        #expect(config.groupKeyBase64 == sequentialBase64)
    }

    @Test
    func parsePairURIValidAndInvalid() {
        let uri = "chat94://pair/\(sequentialBase64URL)"
        #expect(GroupConfig.fromGroupURI(uri)?.groupKey == sequentialKey)
        #expect(GroupConfig.fromGroupURI("https://example.com/pair/\(sequentialBase64URL)") == nil)
        #expect(GroupConfig.fromGroupURI("chat94://pair/short") == nil)
    }

    @Test
    func pairIdMatchesExpectedHex() throws {
        let config = try #require(GroupConfig(base64Key: sequentialBase64))
        #expect(config.groupId == "630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd")
    }

    @Test
    func isValidChecks32ByteKeyLength() {
        #expect(GroupConfig(base64Key: sequentialBase64)?.isValid == true)
        #expect(GroupConfig(base64Key: Data(repeating: 1, count: 31).base64EncodedString()) == nil)
    }

    @Test
    func parseAcceptsUriBase64URLAndStandardBase64() {
        let uri = "chat94://pair/\(sequentialBase64URL)"
        #expect(GroupConfig.parse(uri)?.groupKey == sequentialKey)
        #expect(GroupConfig.parse(sequentialBase64URL)?.groupKey == sequentialKey)
        #expect(GroupConfig.parse(sequentialBase64)?.groupKey == sequentialKey)
        #expect(GroupConfig.parse("invalid") == nil)
    }
}
