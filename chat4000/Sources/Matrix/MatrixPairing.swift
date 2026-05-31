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
        let redeemed = try await post(url: url, code: code, deviceName: deviceName)
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

    /// One redeem attempt with a single retry on transient failure. Safe because
    /// redeem is idempotent within `REDEEM_RESULT_TTL` (§3.4): a retry returns
    /// the same credentials.
    private static func post(url: URL, code: String, deviceName: String, attempt: Int = 0) async throws -> RedeemResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "device_name": deviceName])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MatrixError.pairingFailed("no HTTP response")
            }
            if (200..<300).contains(http.statusCode) {
                return try JSONDecoder().decode(RedeemResponse.self, from: data)
            }
            // 503 leaves the code redeemable — retry once.
            if http.statusCode == 503, attempt == 0 {
                try? await Task.sleep(for: .milliseconds(600))
                return try await post(url: url, code: code, deviceName: deviceName, attempt: 1)
            }
            throw MatrixError.pairingFailed(friendlyMessage(status: http.statusCode, body: data))
        } catch let error as MatrixError {
            throw error
        } catch {
            // Network-level failure — retry once (idempotent within the TTL window).
            if attempt == 0 {
                try? await Task.sleep(for: .milliseconds(600))
                return try await post(url: url, code: code, deviceName: deviceName, attempt: 1)
            }
            throw MatrixError.pairingFailed(error.localizedDescription)
        }
    }

    /// Map the spec's `{ errcode }` (§3.4) to a human message.
    private static func friendlyMessage(status: Int, body: Data) -> String {
        let parsed = try? JSONDecoder().decode(MatrixApiError.self, from: body)
        switch (status, parsed?.errcode) {
        case (410, "M_CODE_EXPIRED"): return "This pairing code has expired — generate a new one."
        case (410, _): return "This pairing code was already used — generate a new one."
        case (429, _): return "Too many attempts. Wait a moment and try again."
        case (404, _), (400, _): return "Invalid pairing code."
        case (503, _): return "Server unavailable. Please try again."
        default: return parsed?.error.isEmpty == false ? parsed!.error : "Pairing failed (HTTP \(status))"
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
