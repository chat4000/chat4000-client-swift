// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

#if os(macOS)
import AppKit
import Foundation

/// macOS-only in-app DMG self-updater (protocol C.5.3). POSTs `/macos-update`,
/// drives the download → fail-closed verify (sha256 + Team-ID `H45JD827CU` +
/// notarization) → stage → atomic-swap-and-relaunch flow, and exposes an
/// `@Observable` state machine the UI binds to. Mirrors `VersionPolicyManager`'s
/// conventions (registrar base via `MatrixEnvironment.current`, `X-Client-Id`
/// via `ClientIdentity`, logging via `AppLog`, telemetry via `TelemetryManager`).
///
/// This is distinct from `VersionPolicyManager` (`/version`, the nag/force gate):
/// only this endpoint returns an installable, verifiable artifact, and only the
/// macOS Developer-ID DMG build self-updates.
@MainActor
@Observable
final class MacUpdater {
    /// The wire `action` (protocol C.5.3). Raw values are the EXACT spec strings.
    enum WireAction: String {
        case ok
        case upgrade
        case forceUpgrade = "force_upgrade"
    }

    /// Where a "Relaunch to update" tap originated (CL26 `relaunch_clicked`
    /// `surface` prop).
    enum RelaunchSurface: String {
        case pill
        case popup
        case forceScreen = "force_screen"
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(version: String, fraction: Double)
        case verifying(version: String)
        case readyToInstall(version: String)
        case forced(version: String)
        case failed(reason: String)
    }

    static let shared = MacUpdater()
    private init() {}

    private(set) var state: State = .idle

    /// True once the staged build is verified and a one-click install is possible
    /// (drives the pill + the force-screen "Update Now" button).
    var isReadyToInstall: Bool {
        if case .readyToInstall = state { return true }
        return false
    }

    /// The version currently offered/ready, for UI labels.
    var offeredVersion: String? {
        switch state {
        case .downloading(let v, _), .verifying(let v), .readyToInstall(let v), .forced(let v):
            return v
        default:
            return nil
        }
    }

    /// True when the registrar forced an upgrade — App should block with the
    /// update-required screen (wired into the force-gate in `chat4000App`).
    var isForced: Bool {
        if case .forced = state { return true }
        return false
    }

    // MARK: - Scheduling state

    private var lastCheckAt: Date?
    private var inFlight: Bool = false
    private var hourlyLoopStarted: Bool = false
    /// Versions for which the one-shot "update available" popup was already shown.
    private var popupShownVersions: Set<String> = []
    /// Session-local dismissal of the popup (the pill persists regardless).
    private(set) var popupDismissedThisSession: Bool = false
    /// The current target version that should drive the popup (set on `upgrade`).
    private(set) var popupVersion: String?

    private static let debounceInterval: TimeInterval = 60
    private static let hourlyInterval: UInt64 = 3600 * 1_000_000_000 // ns

    private static let popupShownDefaultsKey: String = "macUpdate.popupShownVersions"

    // MARK: - Wire response

    private struct Response: Decodable {
        let action: String
        let version: String?
        let dmgURL: String?
        let sha256: String?

        enum CodingKeys: String, CodingKey {
            case action
            case version
            case dmgURL = "dmg_url"
            case sha256
        }
    }

    /// One verified update target, carried through the flow.
    private struct Target {
        let version: String
        let dmgURL: URL
        let sha256: String
        let action: WireAction
        let fromVersion: String
    }

    // MARK: - Public entry points

    /// Cold launch: schedule the first check + start the hourly loop. Async /
    /// non-blocking (protocol C.5.3: "must not poll on the message path").
    func startScheduling() {
        loadPopupShownVersions()
        Task { await check() }
        startHourlyLoopIfNeeded()
    }

    /// Foreground-resume check (debounced).
    func checkOnForeground() {
        Task { await check() }
    }

    /// POST `/macos-update`, decode, and auto-run the download on
    /// `upgrade`/`force_upgrade`. Debounced (~60s) + in-flight no-op + semver
    /// guard so a version ≤ ours is never offered.
    func check() async {
        guard !inFlight else { return }
        if let last = lastCheckAt, Date().timeIntervalSince(last) < Self.debounceInterval {
            return
        }
        inFlight = true
        lastCheckAt = Date()
        defer { inFlight = false }

        // Already mid-flow (downloading/verifying/ready/forced) — don't restart.
        switch state {
        case .downloading, .verifying, .readyToInstall, .forced:
            return
        default:
            break
        }

        state = .checking
        MacUpdateInstaller.sweepStaleMounts()

        guard let response = await fetch() else {
            // A failed/garbled check is not user-facing — return to idle and let
            // the next scheduled check retry.
            state = .idle
            return
        }

        guard let action = WireAction(rawValue: response.action) else {
            state = .idle
            return
        }

        let currentVersion = AppRegistrationIdentity.currentAppVersion
        switch action {
        case .ok:
            state = .upToDate
        case .upgrade, .forceUpgrade:
            guard let version = response.version,
                  let dmgString = response.dmgURL,
                  let dmgURL = URL(string: dmgString),
                  let sha = response.sha256,
                  !sha.isEmpty else {
                state = .idle
                return
            }
            // Semver guard: never offer a version ≤ what we're already running.
            guard SemVer.isGreater(version, than: currentVersion) else {
                AppLog.log("⬆️ /macos-update offered %@ ≤ current %@ — ignored", version, currentVersion)
                state = .upToDate
                return
            }
            let target = Target(
                version: version,
                dmgURL: dmgURL,
                sha256: sha,
                action: action,
                fromVersion: currentVersion
            )
            trackOffered(target)
            if action == .forceUpgrade {
                state = .forced(version: version)
                track(.macosUpdateForceShown, ["to_version": version])
            } else {
                popupVersion = version
            }
            await runDownloadAndVerify(target)
        }
    }

    /// Install the staged, verified build and relaunch. Driven by the pill, the
    /// popup's "Relaunch now", and the force-screen's "Update Now".
    func installAndRelaunch(surface: RelaunchSurface) {
        guard case .readyToInstall(let version) = state else { return }
        track(.macosUpdateRelaunchClicked, ["to_version": version, "surface": surface.rawValue])

        let stagedApp = Self.stagedAppURL()

        // Edge case: not installed in /Applications (e.g. running from
        // DerivedData) ⇒ don't swap, fall back to opening the DMG so the user
        // can drag it in manually.
        guard MacUpdateInstaller.runningFromInstallDestination() else {
            AppLog.log("⬆️ not running from /Applications — opening staged app for manual install")
            NSWorkspace.shared.open(stagedApp)
            return
        }
        // Edge case: /Applications not writable ⇒ manual-drag fallback (never use
        // the deprecated AuthorizationExecuteWithPrivileges).
        guard MacUpdateInstaller.installDestinationIsWritable() else {
            AppLog.log("⬆️ /Applications not writable — revealing staged app for manual drag")
            NSWorkspace.shared.activateFileViewerSelecting([stagedApp])
            return
        }

        switch MacUpdateInstaller.spawnSwapHelperAndRelaunch(stagedApp: stagedApp) {
        case .success:
            track(.macosUpdateInstalled, ["to_version": version, "from_version": AppRegistrationIdentity.currentAppVersion])
            AppLog.log("⬆️ swap helper spawned; terminating for relaunch into v%@", version)
            NSApp.terminate(nil)
        case .failure(let error):
            reportSwapFailure(error, version: version)
            state = .failed(reason: error.message)
            track(.macosUpdateFailed, ["to_version": version, "reason": "swap_spawn"])
        }
    }

    /// Dismiss the "update available" popup for this session (the pill persists).
    func dismissPopupForSession() {
        popupDismissedThisSession = true
        if let version = popupVersion {
            track(.macosUpdatePopupDismissed, ["to_version": version])
        }
    }

    /// Whether the non-blocking popup should show for the current target: a
    /// verified-ready `upgrade` whose version hasn't had its popup shown yet and
    /// wasn't dismissed this session.
    var shouldShowPopup: Bool {
        guard case .readyToInstall(let version) = state,
              version == popupVersion,
              !popupDismissedThisSession,
              !popupShownVersions.contains(version) else {
            return false
        }
        return true
    }

    /// Mark the popup as shown for `version` (persisted) and emit CL26 shown.
    func markPopupShown(version: String) {
        guard !popupShownVersions.contains(version) else { return }
        popupShownVersions.insert(version)
        persistPopupShownVersions()
        track(.macosUpdatePopupShown, ["to_version": version])
    }

    // MARK: - Download + verify pipeline

    private func runDownloadAndVerify(_ target: Target) async {
        state = .downloading(version: target.version, fraction: 0)
        track(.macosUpdateDownloadStarted, ["to_version": target.version])
        let startedAt = Date()

        let downloadResult = await download(target)
        guard case .success(let dmgURL) = downloadResult else {
            if case .failure(let error) = downloadResult {
                ErrorReporter.capture(error, context: "MacUpdater.download")
                state = .failed(reason: error.message)
                track(.macosUpdateFailed, ["to_version": target.version, "reason": "download"])
            }
            return
        }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: dmgURL.path)[.size] as? Int64) ?? nil
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        var completedProps: [String: Any] = ["to_version": target.version, "duration_ms": durationMs]
        if let bytes { completedProps["bytes"] = bytes }
        track(.macosUpdateDownloadCompleted, completedProps)

        state = .verifying(version: target.version)
        let verified = verify(target, dmgURL: dmgURL)
        switch verified {
        case .success:
            state = .readyToInstall(version: target.version)
            AppLog.log("⬆️ update v%@ verified + staged — ready to install", target.version)
        case .failure(let stage):
            // FAIL CLOSED: delete the download, do NOT swap, raise Sentry, emit CL26.
            MacUpdateInstaller.deleteIfExists(dmgURL)
            MacUpdateInstaller.deleteIfExists(Self.stagedAppURL())
            reportVerifyFailure(stage: stage, target: target)
            track(.macosUpdateVerifyFailed, ["to_version": target.version, "stage": stage.rawValue])
            // For a forced upgrade, keep the block screen (with Retry); otherwise
            // surface failed and let a later check retry.
            if target.action == .forceUpgrade {
                state = .forced(version: target.version)
            } else {
                state = .failed(reason: "Update verification failed (\(stage.rawValue)).")
            }
        }
    }

    /// Download the DMG to a temp file. Disk-space precheck first.
    private func download(_ target: Target) async -> Result<URL, AppError> {
        // Rough precheck: require ~3x an assumed worst-case size on the temp +
        // /Applications volumes (DMG + extracted + staged). We don't know the
        // size yet, so use a conservative 600 MB floor.
        let requiredBytes: Int64 = 600 * 1024 * 1024
        let tempDir = FileManager.default.temporaryDirectory
        guard MacUpdateInstaller.hasFreeSpace(requiredBytes, on: tempDir) else {
            return .failure(.storage("insufficient disk space for update download"))
        }

        let destURL = tempDir.appendingPathComponent("chat4000-\(target.version).dmg")
        MacUpdateInstaller.deleteIfExists(destURL)

        do {
            let (tempFile, response) = try await URLSession.shared.download(from: target.dmgURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                try? FileManager.default.removeItem(at: tempFile)
                return .failure(.httpStatus(code))
            }
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: tempFile, to: destURL)
            return .success(destURL)
        } catch {
            if error is CancellationError { return .failure(.cancelled) }
            ErrorReporter.capture(error, context: "MacUpdater.download(\(target.version))")
            return .failure(.unexpected(error))
        }
    }

    /// Run all THREE verifications in order; on any failure, fail closed.
    /// Returns the failing `VerifyStage` so the caller can report + emit.
    private func verify(_ target: Target, dmgURL: URL) -> Result<Void, MacUpdateInstaller.VerifyStage> {
        // (a) sha256
        if case .failure(let error) = MacUpdateInstaller.verifySHA256(of: dmgURL, expected: target.sha256) {
            AppLog.log("⬆️ sha256 verify failed: %@", error.message)
            return .failure(.sha256)
        }

        // Mount the DMG to inspect the .app for (b) + (c).
        let mountResult = MacUpdateInstaller.attachDMG(dmgURL)
        guard case .success(let mounted) = mountResult else {
            if case .failure(let error) = mountResult {
                AppLog.log("⬆️ DMG attach failed: %@", error.message)
            }
            // A mount failure means we can't verify (b)/(c) — treat as a
            // notarization-stage fail-closed (can't establish trust).
            return .failure(.notarization)
        }
        defer { MacUpdateInstaller.detachDMG(mounted) }

        guard let appURL = Self.locateApp(in: mounted.mountPoint) else {
            AppLog.log("⬆️ no .app found inside mounted DMG")
            return .failure(.teamID)
        }

        // (b) Team-ID signature
        if case .failure(let error) = MacUpdateInstaller.verifyTeamID(of: appURL) {
            AppLog.log("⬆️ team-id verify failed: %@", error.message)
            return .failure(.teamID)
        }
        // (c) Notarization / Gatekeeper
        if case .failure(let error) = MacUpdateInstaller.verifyNotarization(of: appURL) {
            AppLog.log("⬆️ notarization verify failed: %@", error.message)
            return .failure(.notarization)
        }

        // All three passed — stage the verified .app for the swap.
        if case .failure(let error) = MacUpdateInstaller.stage(appURL: appURL, to: Self.stagedAppURL()) {
            AppLog.log("⬆️ staging failed: %@", error.message)
            // Staging failure is not a verification failure; surface as notarization
            // stage so we still fail closed and don't swap.
            return .failure(.notarization)
        }
        return .success(())
    }

    // MARK: - Network

    private func fetch() async -> Response? {
        let env = MatrixEnvironment.current
        guard let url = URL(string: env.registrarBaseURL.trimmedSlash + "/macos-update") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Canonical analytics client_id header (≤64), omitted when telemetry off.
        if let clientId = ClientIdentity.headerClientId() {
            request.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: Self.requestBody())

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = try? JSONDecoder().decode(Response.self, from: data) else {
            return nil
        }
        return parsed
    }

    private static func requestBody() -> [String: Any] {
        var body: [String: Any] = [
            "app_id": AppRegistrationIdentity.currentAppId,
            "client_version": AppRegistrationIdentity.currentAppVersion,
            "platform": "macos"
        ]
        // Legacy fallback rollout key for old builds; new builds rely on the
        // X-Client-Id header. Only sent when telemetry is on.
        if let postHogId = VersionPolicyManager.protocolPostHogId(TelemetryManager.shared.postHogDistinctId) {
            body["posthog_id"] = postHogId
        }
        return body
    }

    // MARK: - Hourly loop

    private func startHourlyLoopIfNeeded() {
        guard !hourlyLoopStarted else { return }
        hourlyLoopStarted = true
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.hourlyInterval)
                guard let self else { return }
                await self.check()
            }
        }
    }

    // MARK: - Analytics

    private func trackOffered(_ target: Target) {
        track(.macosUpdateOffered, [
            "to_version": target.version,
            "from_version": target.fromVersion,
            "action": target.action.rawValue
        ])
    }

    private func track(_ event: AnalyticsEvent, _ properties: [String: Any]) {
        TelemetryManager.shared.track(event, properties: properties)
    }

    // MARK: - Sentry (reuse the existing ErrorReporter sink)

    /// A verification failure is an UNEXPECTED error (protocol C.5.3, DEC sink).
    /// We raise it through the SAME `ErrorReporter`/Sentry sink the rest of the
    /// app uses. `ErrorReporter` fingerprints by error **type + message**, so we
    /// build a dedicated error type whose message embeds the `stage` (and carries
    /// from/to in the message) — that makes the Sentry fingerprint group by stage,
    /// exactly as the spec requires.
    struct VerificationFailure: Error, CustomStringConvertible {
        let stage: String
        let fromVersion: String
        let toVersion: String
        var description: String {
            "macOS update verification failed at stage=\(stage) (\(fromVersion) → \(toVersion))"
        }
    }

    struct SwapFailure: Error, CustomStringConvertible {
        let toVersion: String
        let underlying: String
        var description: String {
            "macOS update swap failed (target \(toVersion)): \(underlying)"
        }
    }

    private func reportVerifyFailure(stage: MacUpdateInstaller.VerifyStage, target: Target) {
        let failure = VerificationFailure(
            stage: stage.rawValue,
            fromVersion: target.fromVersion,
            toVersion: target.version
        )
        ErrorReporter.capture(failure, context: "MacUpdater.verify.\(stage.rawValue)")
    }

    private func reportSwapFailure(_ error: AppError, version: String) {
        let failure = SwapFailure(toVersion: version, underlying: error.message)
        ErrorReporter.capture(failure, context: "MacUpdater.installAndRelaunch.swap")
    }

    // MARK: - Paths

    /// `…/Application Support/chat4000/<ns>/Updates/staging/chat4000.app`.
    static func stagedAppURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("chat4000", isDirectory: true)
            .appendingPathComponent(AppEnvironment.current.storageNamespace, isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent("chat4000.app", isDirectory: true)
    }

    /// Find the `.app` bundle at the root of a mounted DMG volume.
    private static func locateApp(in mountPoint: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: mountPoint,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.first { $0.pathExtension == "app" }
    }

    private func loadPopupShownVersions() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.popupShownDefaultsKey) ?? []
        popupShownVersions = Set(stored)
    }

    private func persistPopupShownVersions() {
        UserDefaults.standard.set(Array(popupShownVersions), forKey: Self.popupShownDefaultsKey)
    }
}

/// Minimal, dependency-free semantic-version comparison for the update guard.
/// Compares dot-separated numeric components left-to-right; missing components
/// are treated as 0. Non-numeric suffixes are ignored (best effort).
enum SemVer {
    static func isGreater(_ lhs: String, than rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedDescending
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = numericComponents(lhs)
        let rhsParts = numericComponents(rhs)
        let count = max(lhsParts.count, rhsParts.count)
        for index in 0..<count {
            let left = index < lhsParts.count ? lhsParts[index] : 0
            let right = index < rhsParts.count ? rhsParts[index] : 0
            if left != right {
                return left < right ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    private static func numericComponents(_ version: String) -> [Int] {
        version.split(separator: ".").map { component in
            let digits = component.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
    }
}

private extension String {
    var trimmedSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}
#endif
