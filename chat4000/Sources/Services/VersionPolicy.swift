import Foundation

/// App-side version/terms gate (protocol C.5). Calls the registrar's
/// `POST /version` on every open and exposes the verdict + current terms
/// version so the app can force/recommend an upgrade and re-prompt terms.
@MainActor
@Observable
final class VersionPolicyManager {
    enum Action: Equatable {
        case ok
        case recommendUpgrade(recommended: String?, message: String?)
        case forceUpgrade(minVersion: String?, recommended: String?, message: String?)
    }

    static let shared = VersionPolicyManager()
    private init() {}

    private(set) var action: Action = .ok
    private(set) var currentTermsVersion: Int?
    /// Session-local dismissal of the recommend banner.
    var nagDismissed = false

    var showNag: Bool {
        if case .recommendUpgrade = action { return !nagDismissed }
        return false
    }

    private struct Response: Decodable {
        let action: String
        let minVersion: String?
        let recommended: String?
        let currentTermsVersion: Int?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case action
            case minVersion = "min_version"
            case recommended
            case currentTermsVersion = "current_terms_version"
            case message
        }
    }

    /// Async, non-blocking (C.5): call on cold launch and every foreground resume.
    func check() async {
        let env = MatrixEnvironment.current
        guard let url = URL(string: env.registrarBaseURL.trimmedSlash + "/version") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: Self.requestBody())

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = try? JSONDecoder().decode(Response.self, from: data) else { return }

        currentTermsVersion = parsed.currentTermsVersion
        switch parsed.action {
        case "force_upgrade":
            action = .forceUpgrade(minVersion: parsed.minVersion, recommended: parsed.recommended, message: parsed.message)
        case "recommend_upgrade":
            action = .recommendUpgrade(recommended: parsed.recommended, message: parsed.message)
        default:
            action = .ok
        }
    }

    func dismissNag() { nagDismissed = true }

    func requireUpgradeFromGateway(minClientVersion: String?, maxClientVersion: String?) {
        let message = "This version of chat4000 is no longer supported by the gateway. Please update to continue."
        action = .forceUpgrade(minVersion: minClientVersion, recommended: nil, message: message)
        AppLog.log(
            "⬆️ gateway version gate min=%@ max=%@",
            minClientVersion ?? "nil",
            maxClientVersion ?? "nil"
        )
    }

    static var releaseChannel: String {
        #if targetEnvironment(simulator)
        return "dev"
        #else
        return Bundle.main.object(forInfoDictionaryKey: "TelemetryDistributionChannel") as? String ?? "dev"
        #endif
    }

    static var platform: String {
        #if os(macOS)
        "macos"
        #else
        "ios"
        #endif
    }

    static func requestBody(postHogDistinctId: String? = TelemetryManager.shared.postHogDistinctId) -> [String: Any] {
        var body: [String: Any] = [
            "app_id": Bundle.main.bundleIdentifier ?? "",
            "client_version": AppRegistrationIdentity.currentAppVersion,
            "release_channel": Self.releaseChannel,
            "platform": Self.platform
        ]
        if let postHogId = protocolPostHogId(postHogDistinctId) {
            body["posthog_id"] = postHogId
        }
        return body
    }

    static func protocolPostHogId(_ raw: String?) -> String? {
        guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty,
              id.count <= 64 else {
            return nil
        }
        return id
    }
}

private extension String {
    var trimmedSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}
