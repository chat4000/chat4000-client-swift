#if os(iOS)
import Foundation
import SwiftUI
import UIKit

@MainActor
@Observable
final class OnboardingManager {
    enum Step: String, CaseIterable {
        // Phase 0 — Notifications
        case notifExplainer = "notif_explainer"
        case notifBlocked = "notif_blocked"
        // Phase 1 — Where did you hear about us
        case pollSource = "poll_source"
        // Phase 2 — Connection (W3-W9)
        case connectHub = "connect_hub"          // W3 — where are you starting from
        case connectDevice = "connect_device"    // W4 — pair from another device
        case installChooser = "install_chooser"  // W5 — chat vs SSH
        case installChat = "install_chat"        // W6 — paste curl into the agent chat
        case installSSH = "install_ssh"          // W7 — run curl on the machine
        case pollExpected = "poll_expected"      // WA — what did you expect
        case teamOffer = "team_offer"            // W9 — talk to the team
    }

    /// W3 hub choices — each is its own analytics value (neither vs don't-know are
    /// distinct, per the owner) and routes to a different window.
    enum ConnectChoice: String {
        case otherDevice = "other_device"   // has chat4000 on another device → W4
        case hasAgent = "has_agent"         // has OpenClaw/Hermes, no chat4000 → W5
        case neither = "neither"            // no chat4000, no agent → WA → W9
        case dontKnow = "dont_know"         // "I don't know what this is" → WA → W9
    }

    enum InstallMethod: String {
        case chat   // paste the curl into the agent chat (Telegram/WhatsApp/…)
        case ssh    // SSH / run on the machine directly
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
    /// Three phases: Notifications, Where, Connection. The notif explainer +
    /// blocked screens are ONE phase (blocked is a detour); everything in the
    /// connection windows (W3-W9) is the third dot.
    var progressPhase: Int {
        switch step {
        case .notifExplainer, .notifBlocked: return 0
        case .pollSource: return 1
        default: return 2
        }
    }

    var progressTotal: Int { 3 }

    struct PollConfig: Codable, Equatable {
        let version: Int
        let questions: [String: PollQuestion]
        /// RG10 build stamp — the deployed registrar commit that served this
        /// config. Echoed back on every answer (RG11/CL32 `poll_commit`) so a
        /// response is attributable to the config version shown. Optional: an
        /// older registrar omits it.
        var commit: String?
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
    /// The W3 choice, kept for the completion event. nil until the user picks.
    private var connectChoice: ConnectChoice?
    /// Chosen install delivery (W5), kept so W6/W7 and the analytics know it.
    private(set) var installMethod: InstallMethod = .chat
    /// Reconnect entry (Disconnect): W3 shows ONLY options 1 & 2 (no neither /
    /// don't-know), and the flow starts straight at the hub.
    private(set) var limitedHub = false
    /// CL31 fires once, at the first hub choice — guard against re-firing.
    private var completionFired = false

    private(set) var step: Step = .notifExplainer
    private(set) var attempts = 0
    /// Set true by `complete()` — the single "onboarding is finished" signal the
    /// view observes to dismiss. Needed because completion can be reached WITHOUT
    /// a step change (OpenClaw/Hermes finish straight from the agent step), so the
    /// view can't rely on `step` alone to know it's done.
    private(set) var isComplete = false
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
        // The flow now OWNS pairing (W3-W9), so ANY unpaired device shows it — it
        // internally skips notifications / where when those are already done and
        // lands on the connect hub. A paired device never sees it.
        return !isAlreadyPaired
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
        Task { await fetchPollConfigWithRetries() }
        Task {
            // Skip phases already satisfied: notifications (if granted) and the
            // "where" poll (if this device already finished the poll portion).
            let granted = await PushNotificationManager.shared.hasNotificationAuthorization()
            if !granted {
                move(to: .notifExplainer, forceTrack: true)
            } else if defaults.bool(forKey: Self.completionDefaultsKey) {
                completionFired = true   // poll portion already done in a past run
                move(to: .connectHub, forceTrack: true)
            } else {
                advanceToSourcePoll()
            }
        }
    }

    /// Disconnect re-entry: jump straight to the connect hub with only the two
    /// "I already have a way in" options (no neither / don't-know), skipping
    /// notifications + where.
    func startForReconnect() {
        started = true
        limitedHub = true
        completionFired = true          // already onboarded once — don't re-fire CL31
        startedAt = Date()
        Task { await fetchPollConfigWithRetries() }
        move(to: .connectHub, forceTrack: true)
    }

    /// QA preview reset (Settings 10-tap): return a REUSED manager to first-run
    /// state so `start()` runs again. Reusing one stable @State object + a plain
    /// bool toggle is what makes the fullScreenCover present reliably (reassigning
    /// the @State object in the same update cycle as the toggle silently fails).
    func resetForRerun() {
        started = false
        isComplete = false
        step = .notifExplainer
        attempts = 0
        viewedSteps = []
        returningFromSettings = false
        pollConfig = nil
        pollUnavailable = false
        pollSkipped = false
        heardFromAnswerId = "unknown"
        connectChoice = nil
        installMethod = .chat
        limitedHub = false
        completionFired = false
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
        move(to: .connectHub)
    }

    /// W3 hub choice — routes to the matching window and, on the first choice,
    /// marks the poll portion complete (CL31 with the choice).
    func chooseConnect(_ choice: ConnectChoice) {
        connectChoice = choice
        fireCompletionOnce()
        switch choice {
        case .otherDevice:      move(to: .connectDevice)
        case .hasAgent:         move(to: .installChooser)
        case .neither, .dontKnow: advanceToExpected()
        }
    }

    /// W5 install-delivery choice → the matching command window.
    func chooseInstall(_ method: InstallMethod) {
        installMethod = method
        move(to: method == .chat ? .installChat : .installSSH)
    }

    /// The Back button per window (W4-W9 → their parent).
    func goBack() {
        switch step {
        case .connectDevice, .installChooser, .pollExpected, .teamOffer:
            move(to: .connectHub)
        case .installChat, .installSSH:
            move(to: .installChooser)
        default:
            break
        }
    }

    private func advanceToExpected() {
        if pollUnavailable, expectedQuestion == nil {
            pollSkipped = true
            move(to: .teamOffer)
        } else {
            move(to: .pollExpected)
        }
    }

    /// RG10: options only ever come from the registrar. Config present → show the
    /// poll; retries exhausted → skip straight to the connect hub; still fetching →
    /// show the step's loading state and let the fetch resolution advance/skip.
    private func advanceToSourcePoll() {
        if defaults.bool(forKey: Self.completionDefaultsKey) {
            completionFired = true
            move(to: .connectHub)               // poll already done in a past run
        } else if pollUnavailable, sourceQuestion == nil {
            pollSkipped = true
            move(to: .connectHub)
        } else {
            move(to: .pollSource)
        }
    }

    /// Called when the fetch retries are exhausted while a poll step is showing
    /// its loading state — skip forward instead of stranding the user.
    private func skipPollStepIfWaiting() {
        if step == .pollSource, sourceQuestion == nil {
            pollSkipped = true
            move(to: .connectHub)
        } else if step == .pollExpected, expectedQuestion == nil {
            pollSkipped = true
            move(to: .teamOffer)
        }
    }

    func answerExpected(option: PollOption, text: String?) {
        postAnswer(questionId: "expected_app", answerId: option.id, answerText: text)
        move(to: .teamOffer)
    }

    /// The view's dismiss signal — used by the QA preview cover (the real flow is
    /// dismissed by the app routing away once pairing succeeds).
    func finish() {
        isComplete = true
    }

    /// Fires ONCE, at the first hub choice: persists the poll-completion flag (so
    /// notifications + where don't rerun) and emits CL31 with the connect choice.
    private func fireCompletionOnce() {
        guard !completionFired else { return }
        completionFired = true
        defaults.set(true, forKey: Self.completionDefaultsKey)
        defaults.removeObject(forKey: Self.forceNextDefaultsKey)   // QA one-shot spent
        let duration = Date().timeIntervalSince(startedAt)
        var properties: [String: Any] = [
            "connect_choice": connectChoice?.rawValue ?? "unknown",
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
        // poll_commit: which config version (RG10 commit) the user was shown.
        let pollCommit = pollConfig?.commit
        if let pollCommit { props["poll_commit"] = pollCommit }
        TelemetryManager.shared.track(.onboardingAnswer, properties: props)
        Task { await postAnswer(questionId: questionId, answerId: answerId, answerText: cappedText, pollCommit: pollCommit, attempt: 0) }
    }

    private func postAnswer(
        questionId: String,
        answerId: String,
        answerText: String?,
        pollCommit: String?,
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
        if let pollCommit { body["poll_commit"] = pollCommit }
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
                await postAnswer(questionId: questionId, answerId: answerId, answerText: answerText, pollCommit: pollCommit, attempt: 1)
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
