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

    func configure(from json: [String: Any]?) {
        config = Config(
            sentryDsn: json?["sentryDsn"] as? String,
            postHogApiKey: json?["posthogApiKey"] as? String,
            postHogHost: json?["posthogHost"] as? String ?? "https://us.i.posthog.com",
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

        let postHogConfig = PostHogConfig(apiKey: apiKey, host: config.postHogHost)
        postHogConfig.captureApplicationLifecycleEvents = false
        postHogConfig.captureScreenViews = false
        postHogConfig.sendFeatureFlagEvent = false
        postHogConfig.errorTrackingConfig.autoCapture = false
        #if os(iOS)
        postHogConfig.sessionReplay = config.postHogSessionReplayEnabled
        #endif
        #if DEBUG
        postHogConfig.debug = true
        #endif
        PostHogSDK.shared.setup(postHogConfig)
        postHogStarted = true
        AppLog.log("📊 PostHog initialized (project_id=%@, host=%@, sessionReplay=%@)",
              config.postHogProjectId ?? "unknown",
              config.postHogHost,
              config.postHogSessionReplayEnabled ? "true" : "false")
    }

    private func stopSentryIfNeeded() {
        guard sentryStarted else { return }
        SentrySDK.close()
        sentryStarted = false
        AppLog.log("📊 Sentry collection disabled")
    }

    private func stopPostHogIfNeeded() {
        guard postHogStarted else { return }
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
            "build_channel": Self.sentryEnvironment,
            "distribution_channel": Self.distributionChannel,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            "build_number": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
        ].merging(properties) { _, new in new }
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

    private static var distributionChannel: String {
        #if targetEnvironment(simulator)
        return "simulator"
        #else
        return Bundle.main.object(forInfoDictionaryKey: "TelemetryDistributionChannel") as? String ?? "development"
        #endif
    }
}
