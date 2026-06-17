// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

#if os(macOS)
import AppKit
import CryptoKit
import Foundation
import Security

/// The exec / OS-integration layer for the macOS DMG self-updater. Each method
/// wraps exactly one `Process` (or one Security.framework call) with captured
/// stdout/stderr + exit status, and converts failures into `AppError` values
/// (Swift production Rule 2). The state machine + orchestration lives in
/// `MacUpdater`; this type is the side-effecting "hands".
///
/// FAIL CLOSED: the verification methods (`verifySHA256`, `verifyTeamID`,
/// `verifyNotarization`) return a `Result` that the orchestrator MUST treat as a
/// hard gate — any failure means refuse to install, delete the download, never
/// swap. The orchestrator also raises a Sentry exception on each verification
/// failure (CL26 `macos_update_verify_failed`).
enum MacUpdateInstaller {
    /// Apple Developer **Team ID** for our Developer-ID signing identity. The
    /// downloaded `.app` MUST be signed by THIS team (not merely "validly signed
    /// by someone") — protocol C.5.3 verification (b).
    static let teamID: String = "H45JD827CU"

    /// The user-facing install destination LaunchServices resolves.
    static let installDestination: URL = URL(fileURLWithPath: "/Applications/chat4000.app")

    /// Which verification stage failed — also the Sentry/PostHog `stage` prop
    /// (CL26 `verify_failed`: `sha256|team_id|notarization`). Conforms to `Error`
    /// so it can be a `Result` failure type in the orchestrator.
    enum VerifyStage: String, Error {
        case sha256
        case teamID = "team_id"
        case notarization
    }

    // MARK: - Captured process result

    /// One process invocation's full outcome — never discards stderr or status.
    struct ProcessResult {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data

        var stdoutString: String { String(bytes: stdout, encoding: .utf8) ?? "" }
        var stderrString: String { String(bytes: stderr, encoding: .utf8) ?? "" }
        var succeeded: Bool { exitCode == 0 }
    }

    /// Run one external executable, capturing stdout/stderr + exit. This is a
    /// boundary adapter (Rule 2): the only place `Process.run()`'s raw `throws`
    /// is converted into an `AppError`.
    static func run(_ launchPath: String, _ arguments: [String]) -> Result<ProcessResult, AppError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Read the pipes on background queues BEFORE waitUntilExit so a child
        // that fills the 64 KiB pipe buffer can't deadlock us. The collector is a
        // lock-guarded reference type so the concurrent reads are Sendable-safe
        // under Swift 6 strict concurrency (mirrors ErrorReporter's NSLock use).
        let collector = PipeCollector()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            collector.setOut(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            collector.setErr(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        do {
            try process.run()
        } catch {
            ErrorReporter.capture(error, context: "MacUpdateInstaller.run(\(launchPath))")
            return .failure(.unexpected(error))
        }
        process.waitUntilExit()
        group.wait()
        return .success(ProcessResult(exitCode: process.terminationStatus, stdout: collector.out, stderr: collector.err))
    }

    /// Lock-guarded holder for the two pipe reads done on background queues.
    /// `@unchecked Sendable`: every access is serialized through `lock`.
    private final class PipeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data()
        private var errData = Data()

        func setOut(_ data: Data) { lock.lock(); outData = data; lock.unlock() }
        func setErr(_ data: Data) { lock.lock(); errData = data; lock.unlock() }
        var out: Data { lock.lock(); defer { lock.unlock() }; return outData }
        var err: Data { lock.lock(); defer { lock.unlock() }; return errData }
    }

    // MARK: - (a) SHA-256 integrity pin

    /// Streamed SHA-256 of `fileURL`, lowercase hex, compared to `expected`.
    /// Streams in 1 MiB chunks so a large DMG never loads fully into memory.
    static func verifySHA256(of fileURL: URL, expected: String) -> Result<Void, AppError> {
        let normalizedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedExpected.isEmpty else {
            return .failure(.invalidConfiguration("empty sha256 in /macos-update response"))
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            ErrorReporter.capture(error, context: "MacUpdateInstaller.verifySHA256.open")
            return .failure(.unexpected(error))
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1 << 20 // 1 MiB
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                ErrorReporter.capture(error, context: "MacUpdateInstaller.verifySHA256.read")
                return .failure(.unexpected(error))
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == normalizedExpected else {
            return .failure(.crypto("sha256 mismatch: expected \(normalizedExpected) got \(actual)"))
        }
        return .success(())
    }

    // MARK: - DMG mount / unmount

    /// A mounted DMG: its device entry + mount point, so we can always detach it.
    struct MountedDMG {
        let mountPoint: URL
        let devEntry: String?
    }

    /// `hdiutil attach -nobrowse -noverify -noautoopen -mountrandom -plist`,
    /// parsing the mount point + dev-entry out of the plist on stdout.
    static func attachDMG(_ dmgURL: URL) -> Result<MountedDMG, AppError> {
        // -mountrandom isolates each mount under /private/var/.../ so concurrent
        // or stale mounts of the same volume name can't collide.
        let mountParent = NSTemporaryDirectory()
        let result = run("/usr/bin/hdiutil", [
            "attach", dmgURL.path,
            "-nobrowse", "-noverify", "-noautoopen",
            "-mountrandom", mountParent,
            "-plist"
        ])
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let proc):
            guard proc.succeeded else {
                return .failure(.storage("hdiutil attach failed (\(proc.exitCode)): \(proc.stderrString)"))
            }
            return parseAttachPlist(proc.stdout)
        }
    }

    /// Parse `hdiutil attach -plist` output: find the system-entity that carries
    /// a `mount-point`, and capture its `dev-entry` for clean detach.
    private static func parseAttachPlist(_ data: Data) -> Result<MountedDMG, AppError> {
        let plist: Any?
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            ErrorReporter.capture(error, context: "MacUpdateInstaller.parseAttachPlist")
            return .failure(.decode("hdiutil attach plist unparseable: \(error.localizedDescription)"))
        }
        guard let root = plist as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]] else {
            return .failure(.decode("hdiutil attach plist missing system-entities"))
        }
        for entity in entities {
            if let mount = entity["mount-point"] as? String, !mount.isEmpty {
                return .success(MountedDMG(
                    mountPoint: URL(fileURLWithPath: mount),
                    devEntry: entity["dev-entry"] as? String
                ))
            }
        }
        return .failure(.storage("hdiutil attach produced no mounted volume"))
    }

    /// `hdiutil detach -force` the mount (by dev-entry if known, else mount point).
    /// Detach failure is logged but never blocks the flow — a leaked mount is a
    /// nuisance, not a correctness problem (swept on next launch).
    static func detachDMG(_ mounted: MountedDMG) {
        let target = mounted.devEntry ?? mounted.mountPoint.path
        let result = run("/usr/bin/hdiutil", ["detach", target, "-force"])
        if case .success(let proc) = result, !proc.succeeded {
            AppLog.log("⬆️ hdiutil detach %@ failed (%d): %@", target, proc.exitCode, proc.stderrString)
        }
    }

    /// Best-effort sweep of stale chat4000 update mounts left by a crash/kill,
    /// so they don't pile up. Detaches any mounted volume whose path is under our
    /// temp mount parent and whose name looks like ours.
    static func sweepStaleMounts() {
        let result = run("/usr/bin/hdiutil", ["info", "-plist"])
        guard case .success(let proc) = result, proc.succeeded else { return }
        guard let plist = try? PropertyListSerialization.propertyList(from: proc.stdout, options: [], format: nil),
              let root = plist as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return }
        for image in images {
            guard let entities = image["system-entities"] as? [[String: Any]] else { continue }
            for entity in entities {
                guard let mount = entity["mount-point"] as? String,
                      mount.hasPrefix(NSTemporaryDirectory()),
                      mount.lowercased().contains("chat4000") else { continue }
                let dev = entity["dev-entry"] as? String ?? mount
                _ = run("/usr/bin/hdiutil", ["detach", dev, "-force"])
                AppLog.log("⬆️ swept stale update mount %@", mount)
            }
        }
    }

    // MARK: - (b) Team-ID signature verification (in-process, Security.framework)

    /// Verify the `.app` at `appURL` is Developer-ID code-signed by OUR Team ID
    /// (`H45JD827CU`), Apple-anchored, with a Developer-ID leaf — in-process via
    /// Security.framework (no `codesign` exec). Checks ALL architectures and
    /// nested code. This is verification (b) of protocol C.5.3.
    static func verifyTeamID(of appURL: URL) -> Result<Void, AppError> {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return .failure(.crypto("SecStaticCodeCreateWithPath failed: \(secErrorString(createStatus))"))
        }

        // anchor apple generic           → chains to the Apple root
        // certificate leaf[subject.OU]   → signed by our Team ID
        // certificate 1[...6.2.6] exists → Developer ID CA (issuer marker OID)
        // certificate leaf[...6.1.13]    → Developer ID Application leaf OID
        let requirementText: String =
            "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" "
            + "and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

        var requirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard reqStatus == errSecSuccess, let req = requirement else {
            return .failure(.crypto("SecRequirementCreateWithString failed: \(secErrorString(reqStatus))"))
        }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let validity = SecStaticCodeCheckValidity(code, flags, req)
        guard validity == errSecSuccess else {
            return .failure(.crypto("Team-ID signature check failed: \(secErrorString(validity))"))
        }
        return .success(())
    }

    // MARK: - (c) Notarization / Gatekeeper acceptance

    /// Verify Gatekeeper/notarization accepts the `.app` for the **install**
    /// operation via `spctl --assess --type install`. (The in-process
    /// `SecAssessmentCreate` SPI is not importable from the public Security
    /// module on this SDK, so we use the public `spctl` tool — protocol C.5.3
    /// explicitly permits either. `spctl` exits non-zero on a rejected/unnotarized
    /// app, so a non-zero status fails closed.) This is verification (c).
    static func verifyNotarization(of appURL: URL) -> Result<Void, AppError> {
        let result = run("/usr/sbin/spctl", ["--assess", "--type", "install", "--verbose=4", appURL.path])
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let proc):
            guard proc.succeeded else {
                let detail = proc.stderrString.isEmpty ? proc.stdoutString : proc.stderrString
                return .failure(.crypto("notarization/Gatekeeper rejected: \(detail)"))
            }
            return .success(())
        }
    }

    // MARK: - Staging (ditto copy into our Application Support dir)

    /// `ditto` the verified `.app` from the DMG into the per-environment staging
    /// dir (`…/chat4000/<ns>/Updates/staging/chat4000.app`). `ditto` preserves
    /// the signature/extended attributes that a plain copy would strip.
    static func stage(appURL: URL, to stagedURL: URL) -> Result<Void, AppError> {
        let stagingDir = stagedURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: stagedURL.path) {
                try FileManager.default.removeItem(at: stagedURL)
            }
        } catch {
            ErrorReporter.capture(error, context: "MacUpdateInstaller.stage.prepare")
            return .failure(.unexpected(error))
        }
        let result = run("/usr/bin/ditto", [appURL.path, stagedURL.path])
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let proc):
            guard proc.succeeded else {
                return .failure(.storage("ditto stage failed (\(proc.exitCode)): \(proc.stderrString)"))
            }
            return .success(())
        }
    }

    // MARK: - Disk-space precheck

    /// Ensure `volumeURL`'s filesystem has at least `requiredBytes` free, so a
    /// download/stage/swap doesn't fail half-way and corrupt the install.
    static func hasFreeSpace(_ requiredBytes: Int64, on volumeURL: URL) -> Bool {
        let values = try? volumeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else {
            // Unknown free space — be permissive rather than blocking an update.
            return true
        }
        return available >= requiredBytes
    }

    // MARK: - The detached two-rename atomic swap + relaunch

    /// Whether the running app lives inside `/Applications` (so an in-place swap
    /// is meaningful). When false (e.g. running from DerivedData) we must NOT
    /// swap — we fall back to opening the DMG (see `MacUpdater`).
    static func runningFromInstallDestination() -> Bool {
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        return bundlePath == installDestination.standardizedFileURL.path
    }

    /// Whether `/Applications` (the swap destination's parent) is writable by us.
    static func installDestinationIsWritable() -> Bool {
        FileManager.default.isWritableFile(atPath: installDestination.deletingLastPathComponent().path)
    }

    /// Spawn a DETACHED helper that waits for THIS process to exit, then does a
    /// two-rename atomic swap of `/Applications/chat4000.app` and `open`s the new
    /// app. Returns after the helper is launched; the caller then terminates the
    /// app so the helper's `kill -0` wait unblocks.
    ///
    /// The swap is same-volume renames only (staged app already lives in our
    /// Application Support dir, which may be a different volume than
    /// `/Applications`, so the helper FIRST `ditto`s staged→`.new` ON the
    /// destination volume, THEN renames). Order:
    ///   1. ditto  staged           → /Applications/chat4000.app.new   (cross-vol copy, slow but safe)
    ///   2. mv     live             → /Applications/chat4000.app.old    (same-vol rename, atomic)
    ///   3. mv     .new             → /Applications/chat4000.app        (same-vol rename, atomic)
    ///   4. keep   .old                                                 (rollback)
    ///   5. open   /Applications/chat4000.app
    static func spawnSwapHelperAndRelaunch(stagedApp: URL) -> Result<Void, AppError> {
        let dest = installDestination
        let helperDir = stagedApp.deletingLastPathComponent().deletingLastPathComponent()
        let helperURL = helperDir.appendingPathComponent("swap-helper.sh")
        let parentPID = ProcessInfo.processInfo.processIdentifier

        let script = swapHelperScript()
        do {
            try script.write(to: helperURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        } catch {
            ErrorReporter.capture(error, context: "MacUpdateInstaller.spawnSwapHelper.write")
            return .failure(.unexpected(error))
        }

        // Reparent the helper to launchd via nohup + background so it outlives
        // our terminate. We pass ppid, staged, dest as positional args.
        let command = "nohup /bin/sh \(shellQuote(helperURL.path)) "
            + "\(parentPID) \(shellQuote(stagedApp.path)) \(shellQuote(dest.path)) "
            + ">/dev/null 2>&1 &"
        let result = run("/bin/sh", ["-c", command])
        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let proc):
            guard proc.succeeded else {
                return .failure(.storage("failed to spawn swap helper (\(proc.exitCode)): \(proc.stderrString)"))
            }
            return .success(())
        }
    }

    /// The helper script source. Positional args: $1=parent_pid $2=staged $3=dest.
    private static func swapHelperScript() -> String {
        """
        #!/bin/sh
        # chat4000 macOS update swap helper. Reparented to launchd; waits for the
        # app (parent_pid) to exit, then atomically swaps /Applications/chat4000.app
        # via two same-volume renames, keeping the old build for rollback, then
        # relaunches. Self-deletes from the staging dir on the way out.
        set -u
        PARENT_PID="$1"
        STAGED="$2"
        DEST="$3"
        NEW="${DEST}.new"
        OLD="${DEST}.old"

        # 1. Wait (bounded) for the parent app to fully exit so no handle pins the bundle.
        i=0
        while kill -0 "$PARENT_PID" 2>/dev/null; do
            i=$((i + 1))
            [ "$i" -ge 120 ] && break   # ~60s cap (0.5s * 120)
            sleep 0.5
        done

        # 2. Copy staged -> .new ON the destination volume (cross-volume copy is fine here).
        rm -rf "$NEW"
        /usr/bin/ditto "$STAGED" "$NEW" || exit 1

        # 3. Two-rename atomic swap (same-volume renames; each mv is atomic).
        rm -rf "$OLD"
        if [ -e "$DEST" ]; then
            mv "$DEST" "$OLD" || exit 1
        fi
        if ! mv "$NEW" "$DEST"; then
            # roll back: restore the old build if the final rename failed.
            [ -e "$OLD" ] && mv "$OLD" "$DEST"
            exit 1
        fi

        # 4. Relaunch the freshly-installed app. (.old is intentionally kept for rollback.)
        /usr/bin/open "$DEST"

        # 5. Best-effort cleanup of the staging copy (the helper itself lives there;
        #    the rm of its own dir is fine on POSIX once the script is mmap'd/running).
        rm -rf "$STAGED" 2>/dev/null
        exit 0
        """
    }

    // MARK: - Fail-closed cleanup

    /// Delete a downloaded/staged artifact (used when verification fails — the
    /// fail-closed contract: never keep an unverified file around).
    static func deleteIfExists(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // Best-effort cleanup; report but don't surface — the install was
            // already refused, this is hygiene.
            ErrorReporter.capture(error, context: "MacUpdateInstaller.deleteIfExists")
        }
    }

    // MARK: - Helpers

    private static func secErrorString(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "\(message) (\(status))"
        }
        return "OSStatus \(status)"
    }

    /// Single-quote a path for safe inclusion in a `/bin/sh -c` command.
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
