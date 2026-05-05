import Foundation

/// Tracks `plugin_version_policy` echoed by the relay (per protocol §6.3) and
/// the plugin's actual running version (observed from inner messages with
/// `from.role == "plugin"`, specifically `from.app_version`).
///
/// Resolves to a `VersionPolicyAction` mirroring `VersionPolicyManager` for
/// the app itself. UI surfaces use this to render a "your paired computer is
/// running an outdated plugin" banner / hard block.
@MainActor
@Observable
final class PluginVersionPolicyManager {
    static let shared = PluginVersionPolicyManager()

    private(set) var action: VersionPolicyAction = .none
    private(set) var latestPolicy: VersionPolicy?
    private(set) var observedPluginVersion: String?
    private(set) var observedPluginBundleId: String?
    private(set) var nagSnoozed: Bool = false

    private let snoozeUntilKey = "chat4000.pluginVersionPolicy.recommendedSnoozedUntil"
    private let snoozedVersionKey = "chat4000.pluginVersionPolicy.recommendedSnoozedVersion"
    private let snoozeDuration: TimeInterval = 60 * 60 * 24 * 30

    var showNag: Bool {
        if case .softNag = action { return !nagSnoozed }
        return false
    }

    var isHardBlocked: Bool {
        if case .hardBlock = action { return true }
        return false
    }

    /// Called from `helloOk` handling. Replaces the current policy. The action
    /// is re-evaluated against the most recently observed plugin version.
    func updatePolicy(_ policy: VersionPolicy?) {
        latestPolicy = policy
        recompute()
    }

    /// Called when an inner message with `from.role == "plugin"` arrives. The
    /// plugin's version is `from.app_version`. We re-evaluate the action and
    /// fire snooze logic per the same rules as the app version policy.
    func observePlugin(version: String?, bundleId: String?) {
        // Plugin version may flip between bundles in pathological cases — if
        // the bundle changed, drop the snooze so the user is reminded again.
        if observedPluginBundleId != bundleId {
            UserDefaults.standard.removeObject(forKey: snoozedVersionKey)
            UserDefaults.standard.removeObject(forKey: snoozeUntilKey)
        }
        observedPluginVersion = version
        observedPluginBundleId = bundleId
        recompute()
    }

    func dismissNag() {
        guard case .softNag(let recommended, _) = action else { return }
        let defaults = UserDefaults.standard
        defaults.set(recommended, forKey: snoozedVersionKey)
        defaults.set(Date().timeIntervalSince1970 + snoozeDuration, forKey: snoozeUntilKey)
        nagSnoozed = true
    }

    private func recompute() {
        // Per §6.3 client behavior: until at least one plugin inner message
        // arrives, no UI. Resolve only when we have an observed plugin version
        // (or pass nil to deliberately trigger the "missing/unparseable →
        // soft-nag, never hard-block" branch).
        guard observedPluginVersion != nil else {
            action = .none
            nagSnoozed = false
            return
        }
        let resolved = VersionPolicyResolver.resolve(
            policy: latestPolicy,
            appVersion: observedPluginVersion
        )
        action = resolved
        nagSnoozed = isCurrentlySnoozed(for: resolved)
    }

    private func isCurrentlySnoozed(for action: VersionPolicyAction) -> Bool {
        guard case .softNag(let recommended, _) = action else { return false }
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: snoozedVersionKey) == recommended else { return false }
        return Date().timeIntervalSince1970 < defaults.double(forKey: snoozeUntilKey)
    }
}
