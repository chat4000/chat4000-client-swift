import Foundation
import Sentry

/// The single error sink (Rule 6). Called ONLY from boundary `catch` blocks
/// when a failure is classified as UNEXPECTED.
///
/// Behaviour:
///   - drops `CancellationError` silently (Rule 5 — cancellation is benign);
///   - fingerprints by error **type + message** (not call site);
///   - rate-limits to **1 per hour per fingerprint** (also dedupes the same
///     error observed at multiple frames);
///   - carries an occurrence count so a burst still records its volume;
///   - never wraps or alters the error.
///
/// Sentry is initialized elsewhere (`TelemetryManager`). `SentrySDK.capture`
/// is a safe no-op when the SDK has not been started, so calling it here is
/// harmless even before / without telemetry init. We never add a DSN here.
enum ErrorReporter {
    private static let lock = NSLock()
    /// fingerprint → last time we forwarded it to the sink.
    /// `nonisolated(unsafe)`: all access is serialized through `lock`.
    nonisolated(unsafe) private static var lastSent: [String: Date] = [:]
    /// fingerprint → occurrences observed since the last forward.
    /// `nonisolated(unsafe)`: all access is serialized through `lock`.
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    /// Record an unexpected error. `context` is autoclosed so building the
    /// string costs nothing when the call is rate-limited away.
    static func capture(_ error: Error, context: @autoclosure () -> String = "") {
        if error is CancellationError { return }

        let fingerprint = "\(type(of: error))|\(error)"

        lock.lock()
        let now = Date()
        let occurrences = (counts[fingerprint] ?? 0) + 1
        counts[fingerprint] = occurrences
        if let last = lastSent[fingerprint], now.timeIntervalSince(last) < 3600 {
            lock.unlock()
            return
        }
        lastSent[fingerprint] = now
        counts[fingerprint] = 0
        let site = context()
        lock.unlock()

        SentrySDK.capture(error: error) { scope in
            scope.setContext(value: ["site": site, "count": occurrences], key: "app")
        }
    }
}
