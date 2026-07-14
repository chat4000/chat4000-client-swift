#if os(iOS)
import Foundation
import SwiftUI
import UIKit

@MainActor
@Observable
final class OnboardingManager {
    enum Step: String, CaseIterable {
        case notifExplainer = "notif_explainer"
        case notifBlocked = "notif_blocked"
        case pollSource = "poll_source"
        case pollAgent = "poll_agent"
        case pollExpected = "poll_expected"
        case interviewOffer = "interview_offer"
    }

    struct PollOption: Identifiable, Codable, Equatable {
        let id: String
        let label: String
        let kind: String

        var isText: Bool { kind == "text" }
    }

    struct PollQuestion: Codable, Equatable {
        let title: String
        var subtitle: String?   // optional server-served explainer (RG10)
        let options: [PollOption]
    }

    /// Progress-dot model (fixes the "1 → 3 jump" when notifications are granted):
    /// the notif explainer + blocked screens are ONE phase (blocked is a detour,
    /// not a step), so granting goes phase 0 → 1, not dot 1 → 3. The neither branch
    /// adds the two extra phases only when the user is actually in it.
    var progressPhase: Int {
        switch step {
        case .notifExplainer, .notifBlocked: return 0
        case .pollSource: return 1
        case .pollAgent: return 2
        case .pollExpected: return 3
        case .interviewOffer: return 4
        }
    }

    var progressTotal: Int {
        switch step {
        case .pollExpected, .interviewOffer: return 5
        default: return hasAgentAnswerId == "neither" ? 5 : 3
        }
    }

    struct PollConfig: Codable, Equatable {
        let version: Int
        let questions: [String: PollQuestion]
    }

    static let completionDefaultsKey = "chat4000.onboardingCompleted.v1"
    /// One-shot QA flag (10 taps on Settings → Devices): rerun the first-run flow
    /// on next launch even though this install is paired/completed.
    static let forceNextDefaultsKey = "chat4000.onboardingForceNext.v1"

    private let defaults: UserDefaults
    private var viewedSteps: Set<Step> = []
    private var started = false
    private var returningFromSettings = false
    private var startedAt = Date()
    private var heardFromAnswerId = "unknown"
    private var hasAgentAnswerId = "neither"

    private(set) var step: Step = .notifExplainer
    private(set) var attempts = 0
    /// nil until the registrar answers — the app ships NO bundled options (RG10).
    private(set) var pollConfig: PollConfig?
    /// Set after the fetch retries are exhausted; poll steps are then skipped.
    private(set) var pollUnavailable = false
    private var pollSkipped = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func needsOnboarding(isAlreadyPaired: Bool, defaults: UserDefaults = .standard) -> Bool {
        if defaults.bool(forKey: forceNextDefaultsKey) { return true }   // QA rerun
        guard !isAlreadyPaired else { return false }
        return !defaults.bool(forKey: completionDefaultsKey)
    }

    /// See `forceNextDefaultsKey` — invoked by the Settings 10-tap QA gesture.
    static func scheduleDebugRerun(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: completionDefaultsKey)
        defaults.set(true, forKey: forceNextDefaultsKey)
    }

    var sourceQuestion: PollQuestion? {
        pollConfig?.questions["heard_from"]
    }

    var expectedQuestion: PollQuestion? {
        pollConfig?.questions["expected_app"]
    }

    func start() {
        guard !started else { return }
        started = true
        startedAt = Date()
        trackStep(.notifExplainer)
        Task { await fetchPollConfigWithRetries() }
    }

    /// QA preview reset (Settings 10-tap): return a REUSED manager to first-run
    /// state so `start()` runs again. Reusing one stable @State object + a plain
    /// bool toggle is what makes the fullScreenCover present reliably (reassigning
    /// the @State object in the same update cycle as the toggle silently fails).
    func resetForRerun() {
        started = false
        step = .notifExplainer
        attempts = 0
        viewedSteps = []
        returningFromSettings = false
        pollConfig = nil
        pollUnavailable = false
        pollSkipped = false
        heardFromAnswerId = "unknown"
        hasAgentAnswerId = "neither"
        startedAt = Date()
    }

    func enableNotifications() {
        attempts += 1
        Task {
            let granted = await PushNotificationManager.shared.requestAuthorizationForOnboarding()
            trackNotificationResult(granted: granted)
            if granted {
                advanceToSourcePoll()
            } else {
                move(to: .notifBlocked, forceTrack: true)
            }
        }
    }

    func openSettings() {
        returningFromSettings = true
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func handleSceneBecameActive() {
        guard step == .notifBlocked, returningFromSettings else { return }
        returningFromSettings = false
        attempts += 1
        Task {
            let granted = await PushNotificationManager.shared.hasNotificationAuthorization()
            trackNotificationResult(granted: granted)
            if granted {
                advanceToSourcePoll()
            } else {
                trackStep(.notifBlocked, force: true)
            }
        }
    }

    func answerSource(option: PollOption, text: String?) {
        heardFromAnswerId = option.id
        postAnswer(questionId: "heard_from", answerId: option.id, answerText: text)
        move(to: .pollAgent)
    }

    func answerAgent(answerId: String) {
        hasAgentAnswerId = answerId
        postAnswer(questionId: "has_agent", answerId: answerId, answerText: nil)
        if answerId == "neither" {
            if pollUnavailable, expectedQuestion == nil {
                pollSkipped = true
                move(to: .interviewOffer)
            } else {
                move(to: .pollExpected)
            }
        } else {
            complete()
        }
    }

    /// RG10: options only ever come from the registrar. Config present → show the
    /// poll; retries exhausted → skip it (CL31 poll_skipped); still fetching →
    /// show the step's loading state and let the fetch resolution advance/skip.
    private func advanceToSourcePoll() {
        if pollUnavailable, sourceQuestion == nil {
            pollSkipped = true
            move(to: .pollAgent)
        } else {
            move(to: .pollSource)
        }
    }

    /// Called when the fetch retries are exhausted while a poll step is showing
    /// its loading state — skip forward instead of stranding the user.
    private func skipPollStepIfWaiting() {
        if step == .pollSource, sourceQuestion == nil {
            pollSkipped = true
            move(to: .pollAgent)
        } else if step == .pollExpected, expectedQuestion == nil {
            pollSkipped = true
            move(to: .interviewOffer)
        }
    }

    func answerExpected(option: PollOption, text: String?) {
        postAnswer(questionId: "expected_app", answerId: option.id, answerText: text)
        move(to: .interviewOffer)
    }

    func complete() {
        defaults.set(true, forKey: Self.completionDefaultsKey)
        defaults.removeObject(forKey: Self.forceNextDefaultsKey)   // QA one-shot spent
        let duration = Date().timeIntervalSince(startedAt)
        var properties: [String: Any] = [
            "has_agent": hasAgentAnswerId,
            "heard_from": heardFromAnswerId,
            "duration_bucket": AnalyticsBuckets.onboardingDurationBucket(for: duration)
        ]
        if pollSkipped { properties["poll_skipped"] = true }   // CL31
        TelemetryManager.shared.track(.onboardingCompleted, properties: properties)
    }

    private func move(to nextStep: Step, forceTrack: Bool = false) {
        withAnimation(.easeInOut(duration: 0.24)) {
            step = nextStep
        }
        trackStep(nextStep, force: forceTrack)
    }

    private func trackStep(_ trackedStep: Step, force: Bool = false) {
        guard force || trackedStep == .notifBlocked || !viewedSteps.contains(trackedStep) else { return }
        viewedSteps.insert(trackedStep)
        TelemetryManager.shared.track(
            .onboardingStepViewed,
            properties: ["step": trackedStep.rawValue]
        )
    }

    private func trackNotificationResult(granted: Bool) {
        TelemetryManager.shared.track(
            .onboardingNotificationsResult,
            properties: ["granted": granted, "attempts": attempts]
        )
    }

    /// The options' ONLY source (RG10): retry the registrar up to 10× (5s apart);
    /// success fills the poll screens live, exhaustion skips them (poll_skipped).
    private func fetchPollConfigWithRetries() async {
        for attempt in 0..<10 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(5)) }
            guard pollConfig == nil else { return }
            if let fetched = await fetchPollConfigOnce() {
                pollConfig = fetched
                return
            }
        }
        pollUnavailable = true
        skipPollStepIfWaiting()
    }

    private func fetchPollConfigOnce() async -> PollConfig? {
        let env = MatrixEnvironment.current
        guard let url = URL(string: env.registrarBaseURL.trimmedTrailingSlash + "/onboarding/poll") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        if let clientId = ClientIdentity.headerClientId() {
            request.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let fetched = try? JSONDecoder().decode(PollConfig.self, from: data),
              fetched.questions["heard_from"]?.options.isEmpty == false else {
            return nil
        }
        return fetched
    }

    private func postAnswer(questionId: String, answerId: String, answerText: String?) {
        // Registrar hard-caps free text at 500 (RG11) — truncate client-side so a
        // long answer is stored truncated instead of 400-rejected and lost.
        let cappedText = answerText
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : String($0.prefix(500)) }
        // CL32: the client-side PostHog mirror of RG11 — every answer, emitted the
        // same moment as the registrar POST (product decision: all responses go to
        // PostHog).
        var props: [String: Any] = ["question_id": questionId, "answer_id": answerId]
        if let cappedText { props["answer_text"] = cappedText }
        TelemetryManager.shared.track(.onboardingAnswer, properties: props)
        Task { await postAnswer(questionId: questionId, answerId: answerId, answerText: cappedText, attempt: 0) }
    }

    private func postAnswer(
        questionId: String,
        answerId: String,
        answerText: String?,
        attempt: Int
    ) async {
        let env = MatrixEnvironment.current
        guard let url = URL(string: env.registrarBaseURL.trimmedTrailingSlash + "/onboarding/response") else { return }
        var body: [String: Any] = [
            "question_id": questionId,
            "answer_id": answerId,
            "platform": "ios",
            "app_id": Bundle.main.bundleIdentifier ?? ""
        ]
        if let text = answerText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            body["answer_text"] = text
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let clientId = ClientIdentity.headerClientId() {
            request.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        }
        request.httpBody = data

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 204 else {
            if attempt == 0 {
                try? await Task.sleep(for: .seconds(5))
                await postAnswer(questionId: questionId, answerId: answerId, answerText: answerText, attempt: 1)
            }
            return
        }
    }

}

private extension String {
    var trimmedTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
#endif
