import CommonCrypto
import Foundation

/// In-app diagnostic-bundle collection + upload. Mirrors what
/// `chat4000.com/diagnose.py` did, minus anything blocked by the Mac
/// App Store sandbox (no `sw_vers`, `log show`, `defaults read`, other
/// apps' bundles or crash reports). Works inside the sandbox because
/// it only reads the app's own container and uses Foundation /
/// ProcessInfo for system metadata.
///
/// Triggered by the 20-tap gesture on the "Privacy" header in
/// `SettingsSheet`. Fires PostHog events at every stage so a missing
/// upload still leaves an auditable trail in our analytics.
@MainActor
final class DiagnosticReportService {
    static let shared = DiagnosticReportService()

    enum Status: Equatable {
        case idle
        case collecting
        case encrypting
        case uploading
        case succeeded(url: String)
        case failed(reason: String)
    }

    private(set) var status: Status = .idle {
        didSet {
            NotificationCenter.default.post(name: Self.statusChanged, object: status)
        }
    }

    static let statusChanged = Notification.Name("chat4000.DiagnosticReportService.statusChanged")

    /// Matches `diagnose.py`'s `SHARED_PASSWORD`. Decryption command:
    ///   openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
    ///     -in bundle.enc -out bundle.tar.gz -pass pass:<this>
    private static let sharedPassword = "chat4000-support-diag-shared-2026"
    private static let posthogHost = "https://us.i.posthog.com"
    private static let posthogApiKey = "phc_s49DnTamyFDnEC6MyumNmmjjf7p455LXCVzPE94hPemZ"
    private static let uploadEndpoint = "https://uguu.se/upload"

    private let sessionId = UUID().uuidString
    private let startedAt = Date()

    private init() {}

    // MARK: - Public API

    /// Kick off the full collect → encrypt → upload pipeline. Safe to
    /// call from a SwiftUI tap handler — never throws, surfaces results
    /// via `status` for observers.
    func runReport() {
        guard status == .idle || isTerminal(status) else { return }
        // Reset to allow re-runs.
        Task { [weak self] in
            guard let self else { return }
            await self.runReportAsync()
        }
    }

    private func runReportAsync() async {
        emit("diagnostic_started")
        status = .collecting

        let json: Data
        do {
            json = try await collectBundleJSON()
            emit(
                "diagnostic_bundle_built",
                ["bundle_size_bytes": json.count]
            )
        } catch {
            emit("diagnostic_collect_failed", ["error": String(describing: error)])
            status = .failed(reason: "Could not collect diagnostics")
            return
        }

        status = .encrypting
        let encrypted: Data
        do {
            encrypted = try Self.encryptOpenSSLCompatible(
                plaintext: json,
                password: Self.sharedPassword
            )
            emit(
                "diagnostic_bundle_encrypted",
                ["bundle_size_bytes": encrypted.count]
            )
        } catch {
            emit("diagnostic_encrypt_failed", ["error": String(describing: error)])
            status = .failed(reason: "Could not encrypt diagnostics")
            return
        }

        status = .uploading
        do {
            let url = try await uploadToUguu(data: encrypted)
            emit(
                "diagnostic_bundle_uploaded",
                [
                    "url": url,
                    "bundle_size_bytes": encrypted.count,
                    "host": "uguu.se",
                    "retention_hours": 48,
                ]
            )
            emit("diagnostic_completed", ["path": "uploaded"])
            status = .succeeded(url: url)
        } catch {
            emit("diagnostic_upload_failed", ["error": String(describing: error)])
            emit("diagnostic_completed", ["path": "upload_failed"])
            status = .failed(reason: "Could not upload diagnostics")
        }
    }

    private func isTerminal(_ status: Status) -> Bool {
        switch status {
        case .succeeded, .failed: return true
        default: return false
        }
    }

    // MARK: - Collection

    /// Builds the diagnostic bundle as JSON. Everything we collect must
    /// be inside the sandbox boundary (app container + ProcessInfo).
    private func collectBundleJSON() async throws -> Data {
        // File I/O is small (capped at 2 MB), runs on main actor —
        // avoids Swift 6 strict-concurrency hassles around bouncing
        // `[String: Any]` across actor boundaries.
        let log = Self.readSelfLog()

        var bundle: [String: Any] = [:]

        bundle["meta"] = [
            "schema": "chat4000-diag-inapp/1",
            "session_id": sessionId,
            "collected_at": ISO8601DateFormatter().string(from: Date()),
        ]
        bundle["app"] = Self.appInfo()
        bundle["system"] = Self.systemInfo()
        bundle["memory"] = Self.memoryInfo()
        bundle["network"] = Self.networkInfo()
        bundle["preferences"] = Self.safeUserDefaults()
        bundle["log"] = log

        return try JSONSerialization.data(
            withJSONObject: bundle,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    nonisolated private static func readSelfLog() -> [String: Any] {
        // App log lives at ~/Library/Containers/<bundle>/Data/Library/Logs/chat4000.log
        // for Mac App Store sandboxed builds (the path we hand AppLog). The
        // unsandboxed dev path is ~/Library/Logs/chat4000.log; try both.
        let candidates: [URL]
        #if os(macOS)
        candidates = [
            FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("Logs/chat4000.log"),
        ].compactMap { $0 }
        #else
        candidates = [
            FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("Logs/chat4000.log"),
        ].compactMap { $0 }
        #endif

        for url in candidates {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            // Cap to last 2 MB; redact obvious secrets.
            let trimmed: Data
            if data.count > 2_000_000 {
                trimmed = data.suffix(2_000_000)
            } else {
                trimmed = data
            }
            let raw = String(data: trimmed, encoding: .utf8) ?? "<binary>"
            return [
                "source": url.path,
                "size_bytes": data.count,
                "content": Self.redact(raw),
            ]
        }
        return [
            "source": "<not found>",
            "checked_paths": candidates.map { $0.path },
        ]
    }

    nonisolated private static func redact(_ text: String) -> String {
        var output = text
        // 64-hex APNS device tokens
        output = output.replacingOccurrences(
            of: #"\b[0-9a-f]{64}\b"#,
            with: "<redacted-64hex>",
            options: .regularExpression
        )
        // group_id=<long hex>
        output = output.replacingOccurrences(
            of: #"(group_id[=:\s]+)([0-9a-f]{16,})"#,
            with: "$1<redacted-group>",
            options: .regularExpression
        )
        // device_token=<value>
        output = output.replacingOccurrences(
            of: #"(device_token[=:\s]+)([0-9a-fA-F]{16,})"#,
            with: "$1<redacted>",
            options: .regularExpression
        )
        return output
    }

    private static func appInfo() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "bundle_id": Bundle.main.bundleIdentifier ?? "",
            "version": info["CFBundleShortVersionString"] as? String ?? "",
            "build": info["CFBundleVersion"] as? String ?? "",
            "executable": info["CFBundleExecutable"] as? String ?? "",
            "display_name": info["CFBundleDisplayName"] as? String ?? "",
            "telemetry_distribution_channel": info["TelemetryDistributionChannel"] as? String ?? "",
            "minimum_system_version": info["LSMinimumSystemVersion"] as? String ?? "",
            "sdk_name": info["DTSDKName"] as? String ?? "",
            "xcode_build": info["DTXcodeBuild"] as? String ?? "",
        ]
    }

    private static func systemInfo() -> [String: Any] {
        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        let locale = Locale.current
        return [
            "macos_version": "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)",
            "macos_full": ProcessInfo.processInfo.operatingSystemVersionString,
            "host_name": ProcessInfo.processInfo.hostName,
            "user_name": NSUserName(),
            "machine": Self.machineArch(),
            "processor_count": ProcessInfo.processInfo.processorCount,
            "active_processor_count": ProcessInfo.processInfo.activeProcessorCount,
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "system_uptime_secs": Int(ProcessInfo.processInfo.systemUptime),
            "locale_identifier": locale.identifier,
            "locale_language_code": locale.language.languageCode?.identifier ?? "",
            "locale_region_code": locale.region?.identifier ?? "",
            "timezone": TimeZone.current.identifier,
            "is_low_power": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "thermal_state": Self.thermalState(),
        ]
    }

    private static func machineArch() -> String {
        var sysinfo = utsname()
        guard uname(&sysinfo) == 0 else { return "unknown" }
        return withUnsafePointer(to: &sysinfo.machine) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
    }

    private static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func memoryInfo() -> [String: Any] {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        if kerr == KERN_SUCCESS {
            return [
                "resident_size_bytes": info.resident_size,
                "virtual_size_bytes": info.virtual_size,
            ]
        }
        return ["error": "task_info failed kerr=\(kerr)"]
    }

    private static func networkInfo() -> [String: Any] {
        // Synchronous reachability would block; instead capture what we
        // can statically. Live URLSession probes are too slow for a
        // user-facing tap.
        return [
            "default_relay_url": "wss://relay.chat4000.com/ws",
            // Sandbox blocks reading the system DNS resolvers list, so
            // we leave network probing to the sample we pulled from the
            // user's machine via `diagnose.py` historically.
        ]
    }

    private static func safeUserDefaults() -> [String: Any] {
        let knownKeys = [
            "chat4000.actionButtonMode",
            "chat4000.lastSeenPluginVersion",
            "chat4000.lastSeenPluginBundleId",
            "chat4000.telemetryCollectionEnabled",
            "chat4000.legalConsentAcceptedVersion",
        ]
        let defaults = UserDefaults.standard
        var dump: [String: Any] = [:]
        for key in knownKeys {
            if let value = defaults.object(forKey: key) {
                dump[key] = String(describing: value)
            }
        }
        // Also include all keys (no values) so we can see what exists.
        dump["__all_keys__"] = defaults.dictionaryRepresentation().keys.sorted()
        return dump
    }

    // MARK: - Encryption (OpenSSL "Salted__" + AES-256-CBC + PBKDF2 SHA256, 100k)

    enum EncryptionError: Error { case keyDerivationFailed, encryptFailed }

    static func encryptOpenSSLCompatible(plaintext: Data, password: String) throws -> Data {
        var salt = Data(count: 8)
        let saltResult = salt.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 8, ptr.baseAddress!)
        }
        guard saltResult == errSecSuccess else { throw EncryptionError.keyDerivationFailed }

        // Derive 48 bytes: 32-byte key + 16-byte IV via PBKDF2-SHA256 100k iters.
        var derived = Data(count: 48)
        let kdf = derived.withUnsafeMutableBytes { (derivedPtr: UnsafeMutableRawBufferPointer) -> Int32 in
            salt.withUnsafeBytes { (saltPtr: UnsafeRawBufferPointer) -> Int32 in
                password.withCString { pwPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr,
                        strlen(pwPtr),
                        saltPtr.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        100_000,
                        derivedPtr.bindMemory(to: UInt8.self).baseAddress,
                        48
                    )
                }
            }
        }
        guard kdf == kCCSuccess else { throw EncryptionError.keyDerivationFailed }
        let key = derived.prefix(32)
        let iv = derived.suffix(16)

        let bufferSize = plaintext.count + kCCBlockSizeAES128
        var output = Data(count: bufferSize)
        var written = 0
        let status = output.withUnsafeMutableBytes { (outPtr: UnsafeMutableRawBufferPointer) -> Int32 in
            key.withUnsafeBytes { (keyPtr: UnsafeRawBufferPointer) -> Int32 in
                iv.withUnsafeBytes { (ivPtr: UnsafeRawBufferPointer) -> Int32 in
                    plaintext.withUnsafeBytes { (ptPtr: UnsafeRawBufferPointer) -> Int32 in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.bindMemory(to: UInt8.self).baseAddress,
                            32,
                            ivPtr.bindMemory(to: UInt8.self).baseAddress,
                            ptPtr.bindMemory(to: UInt8.self).baseAddress,
                            plaintext.count,
                            outPtr.bindMemory(to: UInt8.self).baseAddress,
                            bufferSize,
                            &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw EncryptionError.encryptFailed }
        output.count = written

        // OpenSSL framing: "Salted__" || salt(8) || ciphertext.
        var framed = Data()
        framed.append("Salted__".data(using: .ascii)!)
        framed.append(salt)
        framed.append(output)
        return framed
    }

    // MARK: - Upload

    enum UploadError: Error { case noUrlInResponse, badStatus(Int), badBody(String) }

    private func uploadToUguu(data: Data) async throws -> String {
        let boundary = "----chat4000-diag-\(UUID().uuidString)"
        let filename = "chat4000-diag-\(ISO8601DateFormatter().string(from: Date())).enc"

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"files[]\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: Self.uploadEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("chat4000-diagnose-inapp/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = body
        req.timeoutInterval = 60

        let (respData, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw UploadError.badStatus(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let files = json["files"] as? [[String: Any]],
              let first = files.first,
              let url = first["url"] as? String
        else {
            throw UploadError.noUrlInResponse
        }
        return url
    }

    // MARK: - PostHog (fire-and-forget, mirrors diagnose.py event names)

    private func emit(_ event: String, _ extras: [String: Any] = [:]) {
        #if os(macOS)
        let platformName = "macos"
        #else
        let platformName = "ios"
        #endif
        var properties: [String: Any] = [
            "$lib": "chat4000-diagnose-inapp",
            "$lib_version": "1.0",
            "platform": platformName,
            "session_id": sessionId,
            "elapsed_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
            "host_name": ProcessInfo.processInfo.hostName,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "app_build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            "app_bundle_id": Bundle.main.bundleIdentifier ?? "",
            "macos_version": {
                let v = ProcessInfo.processInfo.operatingSystemVersion
                return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            }(),
        ]
        for (k, v) in extras { properties[k] = v }

        let payload: [String: Any] = [
            "api_key": Self.posthogApiKey,
            "event": event,
            "distinct_id": distinctId(),
            "properties": properties,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var req = URLRequest(url: URL(string: "\(Self.posthogHost)/i/v0/e/")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("chat4000-diagnose-inapp/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = body
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req).resume()
    }

    private func distinctId() -> String {
        // Stable per-machine id derived from hostname. We deliberately
        // don't pull the IOPlatformUUID (sandbox can't read ioreg).
        "mac-\(ProcessInfo.processInfo.hostName)"
    }
}
