import Foundation
import Testing
@testable import chat94

struct VersionPolicyTests {
    @Test
    func policyAbsentReturnsNone() {
        let action = VersionPolicyResolver.resolve(policy: nil, appVersion: "1.0.0")
        #expect(action == .none)
    }

    @Test
    func policyWithAllFieldsNullReturnsNone() {
        let policy = VersionPolicy(minVersion: nil, recommendedVersion: nil, latestVersion: nil)
        let action = VersionPolicyResolver.resolve(policy: policy, appVersion: "1.0.0")
        #expect(action == .none)
    }

    @Test
    func belowMinVersionHardBlocks() {
        let policy = VersionPolicy(
            minVersion: "1.0.0",
            recommendedVersion: "1.2.0",
            latestVersion: "1.3.0"
        )
        let action = VersionPolicyResolver.resolve(policy: policy, appVersion: "0.9.5")
        #expect(action == .hardBlock(minVersion: "1.0.0", latestVersion: "1.3.0"))
    }

    @Test
    func atMinVersionDoesNotHardBlock() {
        let policy = VersionPolicy(minVersion: "1.0.0", recommendedVersion: nil, latestVersion: nil)
        let action = VersionPolicyResolver.resolve(policy: policy, appVersion: "1.0.0")
        #expect(action == .none)
    }

    @Test
    func minOnlyBelowHardBlocks() {
        let policy = VersionPolicy(minVersion: "2.0.0", recommendedVersion: nil, latestVersion: nil)
        let action = VersionPolicyResolver.resolve(policy: policy, appVersion: "1.5.0")
        #expect(action == .hardBlock(minVersion: "2.0.0", latestVersion: nil))
    }

    @Test
    func belowRecommendedSoftNags() {
        let policy = VersionPolicy(
            minVersion: "1.0.0",
            recommendedVersion: "1.2.0",
            latestVersion: "1.3.0"
        )
        let action = VersionPolicyResolver.resolve(policy: policy, appVersion: "1.1.0")
        #expect(action == .softNag(recommendedVersion: "1.2.0", latestVersion: "1.3.0"))
    }

    @Test
    func atOrAboveRecommendedReturnsNone() {
        let policy = VersionPolicy(
            minVersion: "1.0.0",
            recommendedVersion: "1.2.0",
            latestVersion: "1.3.0"
        )
        #expect(VersionPolicyResolver.resolve(policy: policy, appVersion: "1.2.0") == .none)
        #expect(VersionPolicyResolver.resolve(policy: policy, appVersion: "1.5.0") == .none)
    }

    @Test
    func unparseableAppVersionWithRecommendedSoftNagsNeverHardBlocks() {
        let policy = VersionPolicy(minVersion: "5.0.0", recommendedVersion: "5.1.0", latestVersion: nil)
        let action = VersionPolicyResolver.resolve(policy: policy, appVersion: "not-a-version")
        #expect(action == .softNag(recommendedVersion: "5.1.0", latestVersion: nil))
    }

    @Test
    func unparseableAppVersionWithOnlyMinReturnsNone() {
        let policy = VersionPolicy(minVersion: "5.0.0", recommendedVersion: nil, latestVersion: nil)
        let action = VersionPolicyResolver.resolve(policy: policy, appVersion: "garbage")
        #expect(action == .none)
    }

    @Test
    func nilAppVersionWithRecommendedSoftNags() {
        let policy = VersionPolicy(minVersion: "1.0.0", recommendedVersion: "1.2.0", latestVersion: nil)
        let action = VersionPolicyResolver.resolve(policy: policy, appVersion: nil)
        #expect(action == .softNag(recommendedVersion: "1.2.0", latestVersion: nil))
    }

    @Test
    func semverCompareNumericOrder() {
        #expect(SemverCompare.compare("1.0.0", "1.0.0") == .orderedSame)
        #expect(SemverCompare.compare("1.0.0", "1.0.1") == .orderedAscending)
        #expect(SemverCompare.compare("1.10.0", "1.9.0") == .orderedDescending)
        #expect(SemverCompare.compare("2.0", "2.0.0") == .orderedSame)
        #expect(SemverCompare.compare("garbage", "1.0.0") == nil)
        #expect(SemverCompare.compare("1.0.0", "1.0.0-beta") == .orderedSame)
    }

    @Test
    func helloOkParsesVersionPolicy() throws {
        let json = #"{"version":1,"type":"hello_ok","payload":{"current_terms_version":200,"version_policy":{"min_version":"1.0.0","recommended_version":"1.2.0","latest_version":"1.3.0"}}}"#
        let parsed = try #require(RelayMessage.parse(from: json))
        guard case .helloOk(let terms, let policy) = parsed else {
            Issue.record("expected hello_ok")
            return
        }
        #expect(terms == 200)
        #expect(policy?.minVersion == "1.0.0")
        #expect(policy?.recommendedVersion == "1.2.0")
        #expect(policy?.latestVersion == "1.3.0")
    }

    @Test
    func helloOkWithoutVersionPolicy() throws {
        let json = #"{"version":1,"type":"hello_ok","payload":{"current_terms_version":200}}"#
        let parsed = try #require(RelayMessage.parse(from: json))
        guard case .helloOk(_, let policy) = parsed else {
            Issue.record("expected hello_ok")
            return
        }
        #expect(policy == nil)
    }

    @Test
    func helloOkWithVersionPolicyAllNullsParses() throws {
        let json = #"{"version":1,"type":"hello_ok","payload":{"current_terms_version":200,"version_policy":{"min_version":null,"recommended_version":null,"latest_version":null}}}"#
        let parsed = try #require(RelayMessage.parse(from: json))
        guard case .helloOk(_, let policy) = parsed else {
            Issue.record("expected hello_ok")
            return
        }
        let resolved = try #require(policy)
        #expect(resolved.minVersion == nil)
        #expect(resolved.recommendedVersion == nil)
        #expect(resolved.latestVersion == nil)
        #expect(VersionPolicyResolver.resolve(policy: resolved, appVersion: "0.0.1") == .none)
    }
}
