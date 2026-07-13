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
        let options: [PollOption]
    }

    struct PollConfig: Codable, Equatable {
        let version: Int
        let questions: [String: PollQuestion]
    }

    static let completionDefaultsKey = "chat4000.onboardingCompleted.v1"

    private let defaults: UserDefaults
    private var viewedSteps: Set<Step> = []
    private var started = false
    private var returningFromSettings = false
    private var startedAt = Date()
    private var heardFromAnswerId = "unknown"
    private var hasAgentAnswerId = "neither"

    private(set) var step: Step = .notifExplainer
    private(set) var attempts = 0
    private(set) var pollConfig: PollConfig = OnboardingManager.defaultPollConfig

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func needsOnboarding(isAlreadyPaired: Bool, defaults: UserDefaults = .standard) -> Bool {
        guard !isAlreadyPaired else { return false }
        return !defaults.bool(forKey: completionDefaultsKey)
    }

    var sourceQuestion: PollQuestion {
        pollConfig.questions["heard_from"] ?? Self.defaultPollConfig.questions["heard_from"] ?? Self.fallbackSourceQuestion
    }

    var expectedQuestion: PollQuestion {
        pollConfig.questions["expected_app"] ?? Self.defaultPollConfig.questions["expected_app"] ?? Self.fallbackExpectedQuestion
    }

    func start() {
        guard !started else { return }
        started = true
        startedAt = Date()
        trackStep(.notifExplainer)
        Task { await fetchPollConfig() }
    }

    func enableNotifications() {
        attempts += 1
        Task {
            let granted = await PushNotificationManager.shared.requestAuthorizationForOnboarding()
            trackNotificationResult(granted: granted)
            if granted {
                move(to: .pollSource)
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
                move(to: .pollSource)
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
            move(to: .pollExpected)
        } else {
            complete()
        }
    }

    func answerExpected(option: PollOption, text: String?) {
        postAnswer(questionId: "expected_app", answerId: option.id, answerText: text)
        move(to: .interviewOffer)
    }

    func complete() {
        defaults.set(true, forKey: Self.completionDefaultsKey)
        let duration = Date().timeIntervalSince(startedAt)
        TelemetryManager.shared.track(
            .onboardingCompleted,
            properties: [
                "has_agent": hasAgentAnswerId,
                "heard_from": heardFromAnswerId,
                "duration_bucket": AnalyticsBuckets.onboardingDurationBucket(for: duration)
            ]
        )
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

    private func fetchPollConfig() async {
        let env = MatrixEnvironment.current
        guard let url = URL(string: env.registrarBaseURL.trimmedTrailingSlash + "/onboarding/poll") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        if let clientId = ClientIdentity.headerClientId() {
            request.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let fetched = try? JSONDecoder().decode(PollConfig.self, from: data) else {
            return
        }
        pollConfig = Self.defaultPollConfig.overlaying(fetched)
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

    private static let fallbackSourceQuestion = PollQuestion(
        title: "Where did you hear about us?",
        options: []
    )
    private static let fallbackExpectedQuestion = PollQuestion(
        title: "What did you expect this app to be?",
        options: []
    )

    static let defaultPollConfig = PollConfig(
        version: 2,
        questions: [
            "heard_from": PollQuestion(
                title: "Where did you hear about us?",
                options: [
                    PollOption(id: "friend", label: "A friend told me", kind: "choice"),
                    PollOption(id: "twitter_x", label: "Twitter / X", kind: "choice"),
                    PollOption(id: "discord", label: "Discord", kind: "choice"),
                    PollOption(id: "whatsapp_group", label: "A WhatsApp group", kind: "choice"),
                    PollOption(id: "reddit", label: "Reddit", kind: "choice"),
                    PollOption(id: "other", label: "Other", kind: "text")
                ]
            ),
            "expected_app": PollQuestion(
                title: "What did you expect this app to be?",
                options: [
                    PollOption(id: "chatgpt", label: "ChatGPT", kind: "choice"),
                    PollOption(id: "anthropic", label: "Anthropic / Claude", kind: "choice"),
                    PollOption(id: "other", label: "Something else", kind: "text")
                ]
            )
        ]
    )
}

private extension OnboardingManager.PollConfig {
    func overlaying(_ fetched: OnboardingManager.PollConfig) -> OnboardingManager.PollConfig {
        var merged = questions
        for (key, value) in fetched.questions {
            if !value.title.isEmpty, !value.options.isEmpty {
                merged[key] = value
            }
        }
        return OnboardingManager.PollConfig(version: fetched.version, questions: merged)
    }
}

private extension String {
    var trimmedTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
#endif
