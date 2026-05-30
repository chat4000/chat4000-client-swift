import Foundation
import MatrixRustSDK

/// Device-side onboarding for v2, per `protocol.md` §3.2.
///
/// The plugin reserves a code with the registrar (`/pair/register`); the user
/// reads that code into this app, which redeems it at `POST /pair/redeem`.
/// The registrar creates the user (if needed), logs the new device in
/// **server-side**, and returns ready-to-use Matrix credentials. There is no
/// `m.login.token` round-trip on the client.
///
/// Note: the registrar also returns a `gateway_url` (the WS gateway). This
/// client uses matrix-rust-sdk, which talks to the homeserver directly, so the
/// gateway URL is currently informational only.
enum MatrixPairing {
    /// `POST {registrar}/pair/redeem` response (protocol.md §3.2).
    struct RedeemResponse: Decodable {
        let gatewayUrl: String
        let userId: String
        let deviceId: String
        let accessToken: String

        enum CodingKeys: String, CodingKey {
            case gatewayUrl = "gateway_url"
            case userId = "user_id"
            case deviceId = "device_id"
            case accessToken = "access_token"
        }
    }

    /// Redeem a pairing code → Matrix credentials. `homeserverURL` is the fixed
    /// Tuwunel base URL the SDK will connect to (the registrar does not return
    /// it; it returns the gateway URL).
    static func redeem(
        code: String,
        deviceName: String,
        registrarBaseURL: String,
        homeserverURL: String
    ) async throws -> Session {
        guard let url = URL(string: registrarBaseURL.trimmedTrailingSlash + "/pair/redeem") else {
            throw MatrixError.pairingFailed("invalid registrar URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "device_name": deviceName,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try ensureSuccess(response, data)
        let redeemed = try JSONDecoder().decode(RedeemResponse.self, from: data)

        return Session(
            accessToken: redeemed.accessToken,
            refreshToken: nil,
            userId: redeemed.userId,
            deviceId: redeemed.deviceId,
            homeserverUrl: homeserverURL,
            oauthData: nil,
            slidingSyncVersion: .native
        )
    }

    /// Surfaces the spec's JSON error shape `{ "errcode", "error" }` when present.
    private static func ensureSuccess(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MatrixError.pairingFailed("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(MatrixApiError.self, from: data))
                .map { "\($0.errcode): \($0.error)" }
                ?? (String(data: data, encoding: .utf8) ?? "")
            throw MatrixError.pairingFailed("HTTP \(http.statusCode) \(detail)")
        }
    }
}

/// chat4000 v2 standard error envelope (`protocol.md` conventions).
private struct MatrixApiError: Decodable {
    let errcode: String
    let error: String
}

private extension String {
    var trimmedTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
