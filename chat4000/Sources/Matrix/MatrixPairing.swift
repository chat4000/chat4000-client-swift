import Foundation

/// Device-side onboarding for v2 (protocol C.3). The plugin reserves a 6-digit
/// code with the registrar; the user enters it here, this app redeems it at
/// `POST /codes/{code}/redeem` (the code in the URL path — protocol C.3.2), and
/// the registrar returns ready-to-use gateway credentials (`gateway_url`,
/// `user_id`, `device_id`, `access_token`). No SDK types — the result feeds
/// `GatewayClient` + `CryptoEngine` directly.
///
/// (The registrar retains `POST /pair/redeem` with the code in the body as a
/// back-compat alias for old app builds; this build uses the new path.)
enum MatrixPairing {
    /// Credentials returned by redeem (protocol C.3.2).
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
    ) async throws(AppError) -> Credentials {
        // v2 (protocol C.3.2): the code is the secret in the URL PATH, not the body.
        guard let encodedCode = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: registrarBaseURL.trimmedTrailingSlash + "/codes/" + encodedCode + "/redeem") else {
            throw AppError.pairing("invalid registrar URL")
        }
        return try await post(url: url, deviceName: deviceName)
    }

    /// One redeem attempt with a single retry on transient failure. Safe because
    /// redeem is idempotent within `REDEEM_RESULT_TTL` (C.4): a retry returns the
    /// same credentials.
    private static func post(url: URL, deviceName: String, attempt: Int = 0) async throws(AppError) -> Credentials {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // FLW1: phone client_id on redeem (omitted when telemetry off) so the
        // registrar can stamp it on the pairing rows + hand it to the plugin.
        if let clientId = ClientIdentity.headerClientId() {
            request.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        }
        // v2 (protocol C.3.2): the code is in the URL path; the body carries only
        // the optional device_name.
        guard let body = try? JSONSerialization.data(withJSONObject: ["device_name": deviceName]) else {
            throw AppError.encode("pairing request body")
        }
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppError.pairing("no HTTP response")
            }
            if (200..<300).contains(http.statusCode) {
                guard let creds = try? JSONDecoder().decode(Credentials.self, from: data) else {
                    throw AppError.decode("pairing credentials")
                }
                return creds
            }
            // 503 leaves the code redeemable — retry once.
            if http.statusCode == 503, attempt == 0 {
                try? await Task.sleep(for: .milliseconds(600))
                return try await post(url: url, deviceName: deviceName, attempt: 1)
            }
            throw AppError.pairing(friendlyMessage(status: http.statusCode, body: data))
        } catch let error as AppError {
            throw error
        } catch is CancellationError {
            throw AppError.cancelled
        } catch {
            let urlCode = (error as? URLError)?.code.rawValue ?? 0
            AppLog.log("❌ redeem network error code=%ld host=%@ desc=%@",
                       urlCode, url.host ?? "?", error.localizedDescription)
            // Network-level failure — retry once (idempotent within the TTL window).
            if attempt == 0 {
                try? await Task.sleep(for: .milliseconds(600))
                return try await post(url: url, deviceName: deviceName, attempt: 1)
            }
            throw AppError.pairing(networkMessage(for: error))
        }
    }

    /// Friendly text for transport-level failures (the raw Apple message —
    /// "A server with the specified hostname could not be found" — is confusing;
    /// it's almost always the device's connection/DNS, not the app or server).
    private static func networkMessage(for error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .notConnectedToInternet:
            return "You're offline. Connect to the internet and try again."
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
            return "Can't reach the server — check your connection (Wi-Fi/cellular) and try again."
        case .timedOut, .networkConnectionLost:
            return "The connection dropped. Try again."
        default:
            return "Network error. Check your connection and try again."
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
        default:
            if let parsedError = parsed?.error, !parsedError.isEmpty { return parsedError }
            return "Pairing failed (HTTP \(status))"
        }
    }
}

extension MatrixPairing {
    /// Extract the 6-digit pairing code from raw input — a bare code
    /// (`"322144"` / `"322 144"`) or a `chat4000://pair?code=NNNNNN` QR/URI
    /// payload.
    ///
    /// Naive "keep all digits, take 6" is WRONG for the URI: `chat4000://…`
    /// contributes the digits `4000`, so `chat4000://pair?code=322144` would
    /// yield `400032` instead of `322144` (the bug that produced "invalid
    /// pairing code" on scan). So read the `code` query item first; only fall
    /// back to digit-filtering for a bare typed/pasted code.
    static func extractCode(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comps = URLComponents(string: trimmed), comps.scheme != nil,
           let codeParam = comps.queryItems?.first(where: { $0.name == "code" })?.value {
            return String(codeParam.filter(\.isNumber).prefix(6))
        }
        return String(trimmed.filter(\.isNumber).prefix(6))
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
