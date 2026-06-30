import Foundation
import PostHog
import Sentry

@MainActor
final class TelemetryManager {
    struct Config {
        let sentryDsn: String?
        let postHogApiKey: String?
        let postHogHost: String
        let postHogProjectId: String?
        let postHogSessionReplayEnabled: Bool
    }

    static let shared = TelemetryManager()

    private var config: Config?
    private var sentryStarted = false
    private var postHogStarted = false

    private init() {}

    var isCollectionEnabled: Bool {
        TelemetryPreferences.isCollectionEnabled
    }

    var postHogDistinctId: String? {
        guard postHogStarted, isCollectionEnabled else { return nil }
        let id = PostHogSDK.shared.getDistinctId().trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// IDN1 — the analytics `client_id` to send (`X-Client-Id`, FLW1/FLW5) and use
    /// as the PostHog distinct_id. nil whenever telemetry is off, so callers omit
    /// the header entirely then.
    var clientId: String? {
        guard isCollectionEnabled else { return nil }
        return ClientIdentity.existingClientId()
    }

    func configure(from json: [String: Any]?) {
        config = Config(
            sentryDsn: json?["sentryDsn"] as? String,
            postHogApiKey: json?["posthogApiKey"] as? String,
            postHogHost: json?["posthogHost"] as? String ?? "https://posthog.chat4000.com",
            postHogProjectId: json?["posthogProjectId"] as? String,
            postHogSessionReplayEnabled: (json?["posthogSessionReplayEnabled"] as? Bool) ?? false
        )
        applyCollectionPreference()
    }

    func setCollectionEnabled(_ enabled: Bool) {
        let previousValue = TelemetryPreferences.isCollectionEnabled
        guard previousValue != enabled else { return }

        if previousValue, !enabled {
            track(
                .telemetryPreferenceChanged,
                properties: ["enabled": false],
                bypassCollectionCheck: true
            )
            flushPostHogIfNeeded()
        }

        TelemetryPreferences.isCollectionEnabled = enabled
        applyCollectionPreference()

        if !previousValue, enabled {
            track(.telemetryPreferenceChanged, properties: ["enabled": true])
        }
    }

    func track(_ event: AnalyticsEvent, properties: [String: Any] = [:], bypassCollectionCheck: Bool = false) {
        guard postHogStarted else { return }
        guard bypassCollectionCheck || isCollectionEnabled else { return }
        let properties = enrichedProperties(properties)
        addEventBreadcrumb(event: event, properties: properties)
        PostHogSDK.shared.capture(event.rawValue, properties: properties)
    }

    func screen(_ name: String, properties: [String: Any] = [:]) {
        guard postHogStarted, isCollectionEnabled else { return }
        let properties = enrichedProperties(properties)
        addScreenBreadcrumb(name: name, properties: properties)
        PostHogSDK.shared.screen(name, properties: properties)
    }

    func flush() {
        flushPostHogIfNeeded()
    }

    /// Flush telemetry before a HARD process exit (e.g. the macOS updater's
    /// swap-and-relaunch calls `NSApp.terminate` within ~1s of capturing
    /// `macos_update_installed`). PostHog's `flush()` is async fire-and-forget, but
    /// `SentrySDK.flush(timeout:)` BLOCKS — so it both delivers any queued Sentry
    /// events AND holds the thread long enough for the in-flight PostHog request
    /// (already sent because `flushAt == 1`) to complete before we die.
    func flushBeforeExit(timeout: TimeInterval = 2.0) {
        flushPostHogIfNeeded()
        if sentryStarted {
            SentrySDK.flush(timeout: timeout)
        }
    }

    /// Sets person-level properties on the current PostHog identity. Used
    /// to attach the APNS device token so the backend can send targeted
    /// push notifications (e.g. founder-chat prompts) via PostHog's
    /// person-property targeting.
    func setPersonProperties(_ properties: [String: Any]) {
        guard postHogStarted, isCollectionEnabled else { return }
        PostHogSDK.shared.capture(
            "$set",
            properties: ["$set": properties]
        )
    }

    private func applyCollectionPreference() {
        guard let config else { return }

        if isCollectionEnabled {
            startSentryIfNeeded(config: config)
            startPostHogIfNeeded(config: config)
        } else {
            stopPostHogIfNeeded()
            stopSentryIfNeeded()
        }
    }

    private func startSentryIfNeeded(config: Config) {
        guard let dsn = config.sentryDsn, !dsn.isEmpty else {
            AppLog.log("📊 Sentry DSN not configured, skipping")
            return
        }
        guard !sentryStarted else { return }

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = Self.sentryEnvironment
            options.releaseName = Self.sentryRelease
            options.attachStacktrace = true
            options.tracesSampleRate = 0
            options.enableAutoSessionTracking = false
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            #if DEBUG
            options.debug = true
            #endif
        }
        sentryStarted = true
        AppLog.log("📊 Sentry initialized")
    }

    private func startPostHogIfNeeded(config: Config) {
        guard let apiKey = config.postHogApiKey, !apiKey.isEmpty else {
            AppLog.log("📊 PostHog API key not configured, skipping")
            return
        }
        guard !postHogStarted else {
            PostHogSDK.shared.optIn()
            return
        }

        // PostHog 3.x renamed `apiKey` → `projectToken` (same value); the old
        // initializer is deprecated and forwards to this one.
        let postHogConfig = PostHogConfig(projectToken: apiKey, host: config.postHogHost)
        postHogConfig.captureApplicationLifecycleEvents = false
        postHogConfig.captureScreenViews = false
        postHogConfig.sendFeatureFlagEvent = false
        postHogConfig.errorTrackingConfig.autoCapture = false
        // Flush every event IMMEDIATELY (flushAt defaults to 20, flushIntervalSeconds
        // to 30). Short-lived macOS sessions — most acutely the updater's
        // capture→swap→relaunch, which terminates us within ~1s — were dropping
        // events that sat batched and never flushed. flushAt=1 sends each event as
        // it's captured; a 10s interval is a backstop only.
        postHogConfig.flushAt = 1
        postHogConfig.flushIntervalSeconds = 10
        // PostHog 3.x defaults to `identifiedOnly` which suppresses person
        // profile creation for anonymous users. We need a profile per device
        // so that `setPersonProperties` (e.g. `apns_device_token`) actually
        // attaches somewhere queryable.
        postHogConfig.personProfiles = .always
        #if os(iOS)
        postHogConfig.sessionReplay = config.postHogSessionReplayEnabled
        #endif
        #if DEBUG
        postHogConfig.debug = true
        #endif
        PostHogSDK.shared.setup(postHogConfig)
        // The PostHog Apple SDK ships as a single `posthog-ios` binary
        // and identifies itself that way even when running on macOS,
        // which makes the PostHog Activity view show "posthog-ios"
        // for every Mac event. Override `$lib` and add an explicit
        // `platform` super-property so we can tell macOS from iOS
        // events at a glance.
        #if os(macOS)
        PostHogSDK.shared.register([
            "$lib": "posthog-macos",
            "platform": "macos",
            "environment": Self.appEnvironmentTag
        ])
        #else
        PostHogSDK.shared.register([
            "platform": "ios",
            "environment": Self.appEnvironmentTag
        ])
        #endif
        postHogStarted = true
        AppLog.log("📊 PostHog initialized (project_id=%@, host=%@, sessionReplay=%@)",
              config.postHogProjectId ?? "unknown",
              config.postHogHost,
              config.postHogSessionReplayEnabled ? "true" : "false")
        bootstrapIdentity()
    }

    /// IDN1/IDN3/INF6 — establish this device's analytics identity once telemetry
    /// is live: classify the (re)install, set `client_id` as the distinct_id, tag
    /// Sentry, and emit exactly one CL3/CL4/CL5 event.
    private func bootstrapIdentity() {
        // IDN3: read marker state BEFORE creating either marker.
        let classification = ClientIdentity.classifyFirstLaunch()
        // IDN1/IDN2: ensure both markers now exist; client_id is the distinct_id.
        let clientId = ClientIdentity.ensureClientId()
        ClientIdentity.ensureAppDeviceId()
        PostHogSDK.shared.identify(clientId)
        // INF6: crashes join product analytics.
        if sentryStarted {
            SentrySDK.configureScope {
                $0.setTag(value: clientId, key: "client_id")
                // Stamp the exact build's git commit on every event so a crash maps
                // straight to its source — and its dSYM — without guessing the build.
                $0.setTag(value: Self.gitCommit, key: "git_commit")
            }
        }
        // CL3/CL4/CL5 — at most one, never on an ordinary launch.
        switch classification {
        case .normalLaunch: break
        case .installed: track(.appInstalled)
        case .reinstalled: track(.appReinstalled)
        case .deviceSwapped: track(.deviceSwapped)
        }
    }

    /// IDN4 / CL6 — once at pairing: emit `account_linked`, $set the `user_id`
    /// person property, and register it as a super property so every later event
    /// (and all of a user's devices) joins natively.
    func linkAccount(userId: String) {
        guard postHogStarted, isCollectionEnabled, !userId.isEmpty else { return }
        PostHogSDK.shared.register(["user_id": userId])
        setPersonProperties(["user_id": userId])
        track(.accountLinked, properties: ["user_id": userId])
    }

    /// Clear the `user_id` super property on disconnect / sign-out (IDN4).
    func clearAccount() {
        guard postHogStarted else { return }
        PostHogSDK.shared.unregister("user_id")
    }

    private func stopSentryIfNeeded() {
        guard sentryStarted else { return }
        SentrySDK.close()
        sentryStarted = false
        AppLog.log("📊 Sentry collection disabled")
    }

    private func stopPostHogIfNeeded() {
        guard postHogStarted else { return }
        // IDN1: opt-out deletes the keychain client_id (and the local marker) so a
        // later reinstall cannot re-link, and resets the SDK's stored ids.
        ClientIdentity.clearForOptOut()
        PostHogSDK.shared.reset()
        PostHogSDK.shared.optOut()
        PostHogSDK.shared.close()
        postHogStarted = false
        AppLog.log("📊 PostHog collection disabled")
    }

    private func flushPostHogIfNeeded() {
        guard postHogStarted else { return }
        PostHogSDK.shared.flush()
    }

    private func addEventBreadcrumb(event: AnalyticsEvent, properties: [String: Any]) {
        guard sentryStarted else { return }

        let breadcrumb = Breadcrumb()
        breadcrumb.level = .info
        breadcrumb.category = "analytics.event"
        breadcrumb.type = "default"
        breadcrumb.message = event.rawValue
        breadcrumb.data = properties
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    private func addScreenBreadcrumb(name: String, properties: [String: Any]) {
        guard sentryStarted else { return }

        let breadcrumb = Breadcrumb()
        breadcrumb.level = .info
        breadcrumb.category = "analytics.screen"
        breadcrumb.type = "navigation"
        breadcrumb.message = name
        breadcrumb.data = properties
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    private func enrichedProperties(_ properties: [String: Any]) -> [String: Any] {
        [
            "environment": Self.appEnvironmentTag,
            "build_channel": Self.sentryEnvironment,
            "distribution_channel": Self.distributionChannel,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            "build_number": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        ].merging(properties) { _, new in new }
    }

    /// Explicit `dev` / `prod` tag attached to every PostHog event and the person
    /// profile, from the per-flavor `APP_ENV` (via `MatrixEnvironment.isStage`):
    /// stage flavors → `dev`, prod flavor → `prod`.
    static var appEnvironmentTag: String {
        MatrixEnvironment.isStage ? "dev" : "prod"
    }

    private static var sentryEnvironment: String {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        if bundleId.hasSuffix(".dev") { return "dev" }
        return "production"
    }

    private static var sentryRelease: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let bundleId = Bundle.main.bundleIdentifier ?? "chat4000"
        return "\(bundleId)@\(version)+\(build)"
    }

    /// Short git SHA of the commit this build was made from, stamped into Info.plist
    /// at build time by the "Stamp git commit" phase. Lets a Sentry event pin the exact
    /// source (and dSYM) — `unknown` for source builds without git.
    static var gitCommit: String {
        Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String ?? "unknown"
    }

    private static var distributionChannel: String {
        #if targetEnvironment(simulator)
        return "simulator"
        #else
        return Bundle.main.object(forInfoDictionaryKey: "TelemetryDistributionChannel") as? String ?? "development"
        #endif
    }
}
