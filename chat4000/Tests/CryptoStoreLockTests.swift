// chat4000
// Copyright (C) 2026 NeonNode Limited
// Licensed under GPL-3.0. See LICENSE file for details.

import Foundation
import Testing
@testable import chat4000

/// Unit tests for `CryptoStoreLock`. These cover IN-PROCESS mutual exclusion (two
/// threads serialize through `withLock`) and the generation/dirty mechanics.
/// True cross-PROCESS exclusion (the real NSE-vs-app case) is device-only and is
/// NOT exercised here — flock against two real processes can't be unit-tested.
struct CryptoStoreLockTests {
    /// Build a lock over a fresh temp directory so each test is isolated.
    private func makeLock() -> (lock: CryptoStoreLock, dir: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CryptoStoreLockTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = CryptoStoreLock(
            lockfileURL: dir.appendingPathComponent("crypto.lock"),
            generationURL: dir.appendingPathComponent("crypto.generation")
        )
        return (lock, dir)
    }

    // MARK: - Mutual exclusion

    /// Shared overlap detector. All mutation is behind its own `NSLock`, so the
    /// type is genuinely thread-safe and can be marked `@unchecked Sendable` to
    /// cross the `DispatchQueue.async` boundary under strict concurrency.
    private final class OverlapDetector: @unchecked Sendable {
        private let guardLock = NSLock()
        private var inside = false
        private(set) var sawOverlap = false
        private(set) var totalRuns = 0

        func enter() {
            guardLock.lock()
            if inside { sawOverlap = true }
            inside = true
            guardLock.unlock()
        }

        func leave() {
            guardLock.lock()
            inside = false
            totalRuns += 1
            guardLock.unlock()
        }
    }

    /// Two threads hammering `withLock` must never have their critical sections
    /// overlap. If either thread sees "inside" already set on entry, the lock
    /// failed to serialize.
    @Test
    func twoThreadsSerialize() {
        let (lock, _) = makeLock()
        let detector = OverlapDetector()
        let iterations = 200
        let group = DispatchGroup()

        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<iterations {
                    lock.withLock {
                        detector.enter()
                        // Tiny busy window to widen the race if the lock is broken.
                        for _ in 0..<50 { _ = UUID().uuidString }
                        detector.leave()
                    }
                }
                group.leave()
            }
        }

        let finished = group.wait(timeout: .now() + 30)
        #expect(finished == .success)
        #expect(detector.sawOverlap == false)
        #expect(detector.totalRuns == iterations * 2)
    }

    /// `withLock` returns the closure's value and re-entrant serial calls work.
    @Test
    func withLockReturnsValueAndIsReusable() {
        let (lock, _) = makeLock()
        let first = lock.withLock { 41 + 1 }
        let second = lock.withLock { "ok" }
        #expect(first == 42)
        #expect(second == "ok")
    }

    /// `withLock` rethrows an error from the closure (and still releases — proven
    /// by being able to take the lock again afterward).
    @Test
    func withLockRethrows() {
        struct Boom: Error {}
        let (lock, _) = makeLock()
        #expect(throws: Boom.self) {
            try lock.withLock { throw Boom() }
        }
        // Lock is free again.
        let after = lock.withLock { true }
        #expect(after == true)
    }

    // MARK: - Generation / dirty detection

    /// A fresh store reads generation 0, and is not dirty relative to 0.
    @Test
    func freshGenerationIsZero() {
        let (lock, _) = makeLock()
        #expect(lock.currentGeneration() == 0)
        #expect(lock.isDirty(since: 0) == false)
    }

    /// `bumpGeneration` increments by one each call and persists.
    @Test
    func bumpIncrements() {
        let (lock, _) = makeLock()
        lock.withLock { lock.bumpGeneration() }
        #expect(lock.currentGeneration() == 1)
        lock.withLock { lock.bumpGeneration() }
        #expect(lock.currentGeneration() == 2)
    }

    /// A caller that remembers gen N before a bump sees `isDirty(since: N)` flip to
    /// true after the bump, and a fresh lock reading the same file agrees (mirrors
    /// a second process reopening the generation file).
    @Test
    func dirtyDetection() {
        let (lock, dir) = makeLock()
        let remembered = lock.currentGeneration()
        #expect(lock.isDirty(since: remembered) == false)

        lock.withLock { lock.bumpGeneration() }
        #expect(lock.isDirty(since: remembered) == true)

        // A separate lock instance over the SAME files observes the new value —
        // the generation lives on disk, not in instance memory.
        let other = CryptoStoreLock(
            lockfileURL: dir.appendingPathComponent("crypto.lock"),
            generationURL: dir.appendingPathComponent("crypto.generation")
        )
        #expect(other.currentGeneration() == remembered + 1)
        #expect(other.isDirty(since: remembered) == true)
        #expect(other.isDirty(since: remembered + 1) == false)
    }
}
