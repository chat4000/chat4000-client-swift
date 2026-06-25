// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// CryptoStoreLock — a cross-PROCESS advisory lock for the Olm/Megolm crypto store.
//
// WHY THIS EXISTS (foundation for the iOS Notification Service Extension, F2):
//   The NSE and the main app are SEPARATE PROCESSES that will both want to open
//   the SAME matrix-sdk-crypto store (the SQLite key store) to decrypt an inbound
//   event. `OlmMachine` is NOT safe to drive from two processes against one store
//   concurrently — overlapping writers corrupt Megolm/Olm session state. This lock
//   serializes them, and a generation counter lets a reader notice the store
//   changed underneath it and reload.
//
// WHAT IT IS:
//   • A `flock(LOCK_EX)` taken on a dedicated SIDECAR lockfile — never on a DB
//     file. Locking the DB file itself risks the OS/SQLite touching it; the
//     sidecar is inert, exists only to be flock'd.
//   • A generation file: a tiny counter a writer bumps (under the lock) after it
//     mutates the store. A reader remembers the generation it last opened at and
//     calls `isDirty(since:)` to learn another process advanced it → reload.
//
// CRITICAL OPERATIONAL RULES (documented, enforced by the caller — NOT by code):
//   • WRITERS MUST NEVER OVERLAP. Every store WRITE must happen inside `withLock`.
//     `flock` is ADVISORY: it only excludes other `flock` callers, so a code path
//     that writes the store WITHOUT taking this lock defeats it entirely.
//   • flock AUTO-FREES ON PROCESS DEATH. The kernel drops the lock when the fd is
//     closed or the process exits/crashes, so a crashed holder cannot deadlock the
//     survivor. (This is why we hold the fd for the lock's lifetime.)
//   • 0xdead10cc — RELEASE BEFORE SUSPENSION. iOS kills a process with exception
//     code 0xdead10cc if it still holds a file lock (flock) on an App-Group/shared
//     file when it gets suspended in the background. Therefore the holder MUST exit
//     `withLock` (releasing the flock) BEFORE it yields to suspension — i.e. do the
//     minimum store work inside the closure and return; never `await` a long
//     suspendable operation or sleep while holding it.
//
// TESTABILITY: the lockfile URL and generation-file URL are INJECTED at init, so
// unit tests point them at a temp dir. The real App-Group container path is wired
// in a LATER phase — this type neither hardcodes nor requires an App Group.
//
// NOTE on test coverage: the unit tests below verify in-PROCESS mutual exclusion
// (two threads serialize) and the generation/dirty mechanics. True cross-PROCESS
// exclusion (the actual NSE-vs-app case) can only be exercised on-device with two
// real processes and is NOT covered by these unit tests.
// ─────────────────────────────────────────────────────────────────────────────

/// Cross-process advisory lock + generation counter for the crypto store.
/// See the file header for the full contract (writers-never-overlap, flock
/// auto-free on death, 0xdead10cc release-before-suspension).
final class CryptoStoreLock: Sendable {
    private let lockfileURL: URL
    private let generationURL: URL

    /// Serializes `withLock` callers WITHIN this process. `flock` already gives
    /// cross-process exclusion; this just keeps two threads of the SAME process
    /// from racing on the single shared fd, which flock does not arbitrate.
    private let intraProcess = NSLock()

    /// - Parameters:
    ///   - lockfileURL: a dedicated sidecar file to `flock`. MUST NOT be a DB file.
    ///   - generationURL: the tiny file holding the generation counter (UInt64
    ///     decimal text). May share a directory with the lockfile.
    init(lockfileURL: URL, generationURL: URL) {
        self.lockfileURL = lockfileURL
        self.generationURL = generationURL
    }

    /// Run `body` while holding an exclusive (`LOCK_EX`) flock on the sidecar
    /// lockfile. The lock is released — and the fd closed — before this returns,
    /// even if `body` throws. Keep `body` SHORT and non-suspendable (see the
    /// 0xdead10cc rule); it is the only safe place to write the store.
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        intraProcess.lock()
        defer { intraProcess.unlock() }

        let fd = openLockfile()
        defer {
            // Releasing the flock is implicit in close(), but be explicit so the
            // intent is unmistakable, then close to free the descriptor.
            flock(fd, LOCK_UN)
            close(fd)
        }

        // Block until we hold the exclusive lock. EINTR (interrupted by a signal)
        // is the only retryable error; anything else means the fd is unusable and
        // we proceed unlocked-but-isolated only within this process. We log and
        // continue rather than crash: a failed flock must not take down the app,
        // and intraProcess still serializes our own threads.
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            AppLog.log("🔒 flock(LOCK_EX) failed errno=%d — proceeding intra-process only", errno)
            break
        }

        return try body()
    }

    // MARK: - Generation / dirty detection

    /// Current generation as recorded in the generation file. A missing or
    /// unparseable file reads as 0 (fresh store, never bumped).
    func currentGeneration() -> UInt64 {
        guard let data = try? Data(contentsOf: generationURL),
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let value = UInt64(text)
        else { return 0 }
        return value
    }

    /// Increment the generation counter and fsync it to durable storage. MUST be
    /// called from inside `withLock` AFTER a store write, so another process that
    /// later compares generations sees that the store changed. Read-modify-write
    /// is safe because the caller holds the exclusive flock.
    func bumpGeneration() {
        let next = currentGeneration() &+ 1
        writeGeneration(next)
    }

    /// True when the generation has advanced past `remembered` — i.e. another
    /// holder wrote the store since the caller last opened/synced it, so the
    /// caller's `OlmMachine` is stale and should `reload()`. Compares `>` so a
    /// caller that remembers the current value is never spuriously dirty.
    func isDirty(since remembered: UInt64) -> Bool {
        currentGeneration() > remembered
    }

    // MARK: - Internals

    /// Open (creating if needed) the sidecar lockfile and return its fd. The file
    /// content is irrelevant — only its existence and the flock on it matter.
    private func openLockfile() -> Int32 {
        let fd = open(lockfileURL.path, O_RDWR | O_CREAT, 0o644)
        if fd < 0 {
            AppLog.log("🔒 open(lockfile) failed errno=%d path=%@", errno, lockfileURL.path)
        }
        return fd
    }

    /// Write the generation file atomically and fsync the bytes so the counter
    /// survives a crash/power-loss right after a store write.
    private func writeGeneration(_ value: UInt64) {
        let text = String(value)
        guard let data = text.data(using: .utf8) else { return }
        do {
            try data.write(to: generationURL, options: .atomic)
            fsyncFile(generationURL)
        } catch {
            AppLog.log("🔒 writeGeneration failed: %@", String(describing: error))
        }
    }

    /// fsync the file's bytes to disk. `Data.write(.atomic)` renames a temp file
    /// into place but does not guarantee the bytes are flushed; this does.
    private func fsyncFile(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        if fsync(fd) != 0 {
            AppLog.log("🔒 fsync(generation) failed errno=%d", errno)
        }
    }
}
