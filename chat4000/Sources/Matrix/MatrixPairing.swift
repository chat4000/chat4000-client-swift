import Foundation

/// Device-side onboarding for v2 (protocol C.2). The plugin reserves a 6-digit
/// code with the registrar; the user enters it here, this app redeems it at
/// `POST /pair/redeem`, and the registrar returns ready-to-use gateway
/// credentials (`gateway_url`, `user_id`, `device_id`, `access_token`). No SDK
/// types — the result feeds `GatewayClient` + `CryptoEngine` directly.
enum MatrixPairing {
    /// Credentials returned by `/pair/redeem` (protocol C.2).
    struct Credentials: Decodable {
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

    /// Redeem a 6-digit pairing code → gateway credentials.
    static func redeem(
        code: String,
        deviceName: String,
        registrarBaseURL: String
    ) async throws -> Credentials {
        guard let url = URL(string: registrarBaseURL.trimmedTrailingSlash + "/pair/redeem") else {
            throw MatrixError.pairingFailed("invalid registrar URL")
        }
        return try await post(url: url, code: code, deviceName: deviceName)
    }

    /// One redeem attempt with a single retry on transient failure. Safe because
    /// redeem is idempotent within `REDEEM_RESULT_TTL` (C.4): a retry returns the
    /// same credentials.
    private static func post(url: URL, code: String, deviceName: String, attempt: Int = 0) async throws -> Credentials {
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
                return try JSONDecoder().decode(Credentials.self, from: data)
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

    /// Map the spec's `{ errcode }` (C.4) to a human message.
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

/// chat4000 v2 standard error envelope (protocol conventions).
private struct MatrixApiError: Decodable {
    let errcode: String
    let error: String
}

private extension String {
    var trimmedTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
