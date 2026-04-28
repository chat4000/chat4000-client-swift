import Foundation

struct VersionPolicy: Decodable, Equatable {
    let minVersion: String?
    let recommendedVersion: String?
    let latestVersion: String?

    enum CodingKeys: String, CodingKey {
        case minVersion = "min_version"
        case recommendedVersion = "recommended_version"
        case latestVersion = "latest_version"
    }
}

enum VersionPolicyAction: Equatable {
    case none
    case softNag(recommendedVersion: String, latestVersion: String?)
    case hardBlock(minVersion: String, latestVersion: String?)
}

enum SemverCompare {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let lhsParts = parts(lhs), let rhsParts = parts(rhs) else { return nil }
        let count = max(lhsParts.count, rhsParts.count)
        for index in 0..<count {
            let l = index < lhsParts.count ? lhsParts[index] : 0
            let r = index < rhsParts.count ? rhsParts[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    static func isParseable(_ version: String) -> Bool {
        parts(version) != nil
    }

    private static func parts(_ version: String) -> [Int]? {
        let core = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
        let segments = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return nil }
        var result: [Int] = []
        for segment in segments {
            guard let number = Int(segment), number >= 0 else { return nil }
            result.append(number)
        }
        return result
    }
}

enum VersionPolicyResolver {
    static func resolve(policy: VersionPolicy?, appVersion: String?) -> VersionPolicyAction {
        guard let policy else { return .none }

        let appParseable: Bool = appVersion.map { SemverCompare.isParseable($0) } ?? false

        if appParseable,
           let appVersion,
           let minVersion = policy.minVersion,
           SemverCompare.compare(appVersion, minVersion) == .orderedAscending {
            return .hardBlock(minVersion: minVersion, latestVersion: policy.latestVersion)
        }

        if let recommended = policy.recommendedVersion {
            if !appParseable {
                return .softNag(recommendedVersion: recommended, latestVersion: policy.latestVersion)
            }
            if let appVersion,
               SemverCompare.compare(appVersion, recommended) == .orderedAscending {
                return .softNag(recommendedVersion: recommended, latestVersion: policy.latestVersion)
            }
        }

        return .none
    }
}

@MainActor
@Observable
final class VersionPolicyManager {
    static let shared = VersionPolicyManager()

    private(set) var action: VersionPolicyAction = .none
    private(set) var latestPolicy: VersionPolicy?
    private(set) var nagSnoozed: Bool = false

    private let snoozeUntilKey = "chat94.versionPolicy.recommendedSnoozedUntil"
    private let snoozedVersionKey = "chat94.versionPolicy.recommendedSnoozedVersion"
    private let snoozeDuration: TimeInterval = 60 * 60 * 24 * 30

    var showNag: Bool {
        if case .softNag = action { return !nagSnoozed }
        return false
    }

    var isHardBlocked: Bool {
        if case .hardBlock = action { return true }
        return false
    }

    func update(with policy: VersionPolicy?) {
        latestPolicy = policy
        let resolved = VersionPolicyResolver.resolve(
            policy: policy,
            appVersion: AppRegistrationIdentity.currentAppVersion
        )
        action = resolved
        nagSnoozed = isCurrentlySnoozed(for: resolved)
    }

    func dismissNag() {
        guard case .softNag(let recommended, _) = action else { return }
        let defaults = UserDefaults.standard
        defaults.set(recommended, forKey: snoozedVersionKey)
        defaults.set(Date().timeIntervalSince1970 + snoozeDuration, forKey: snoozeUntilKey)
        nagSnoozed = true
    }

    private func isCurrentlySnoozed(for action: VersionPolicyAction) -> Bool {
        guard case .softNag(let recommended, _) = action else { return false }
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: snoozedVersionKey) == recommended else { return false }
        return Date().timeIntervalSince1970 < defaults.double(forKey: snoozeUntilKey)
    }
}
