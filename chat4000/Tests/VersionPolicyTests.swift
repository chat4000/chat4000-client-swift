import Testing
@testable import chat4000

@MainActor
struct VersionPolicyTests {
    @Test func versionRequestBodyIncludesValidPostHogId() {
        let body = VersionPolicyManager.requestBody(postHogDistinctId: "ph_distinct_123")

        #expect(body["posthog_id"] as? String == "ph_distinct_123")
        #expect(body["app_id"] as? String != nil)
        #expect(body["client_version"] as? String != nil)
        #expect(body["release_channel"] as? String != nil)
        #expect(body["platform"] as? String != nil)
    }

    @Test func versionRequestBodyOmitsEmptyPostHogId() {
        let body = VersionPolicyManager.requestBody(postHogDistinctId: "  ")

        #expect(body["posthog_id"] == nil)
    }

    @Test func versionRequestBodyOmitsOversizedPostHogId() {
        let body = VersionPolicyManager.requestBody(postHogDistinctId: String(repeating: "x", count: 65))

        #expect(body["posthog_id"] == nil)
    }
}
