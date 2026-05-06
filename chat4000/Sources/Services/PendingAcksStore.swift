import Foundation

/// Persists inner-`ack` `refs` strings received in the background-wake path
/// (silent push wakes the iPhone, the relay forwards plugin's `ack`, but the
/// app process is in the background and SwiftData isn't available). The
/// foreground ChatView drains this list on launch and flips matching local
/// rows from `.sent` → `.delivered`.
///
/// Without this, an inner ack received during a background wake is lost: the
/// background path advances `AckSeqStore` (so the relay won't redrive the
/// frame), but the local `ChatMessage.status` is never updated → the user
/// sees only ✓, never ✓✓.
@MainActor
enum PendingAcksStore {
    private static let key = "chat4000.pendingAcks.refs"

    /// Append a ref. De-dupes against the existing list. Always cheap.
    static func add(_ refs: String) {
        var current = all()
        guard !current.contains(refs) else { return }
        current.append(refs)
        UserDefaults.standard.set(current, forKey: key)
    }

    /// Returns all queued ack refs.
    static func all() -> [String] {
        UserDefaults.standard.array(forKey: key) as? [String] ?? []
    }

    /// Drain the list and return what was queued. Caller is responsible for
    /// applying the refs and saving SwiftData.
    static func drain() -> [String] {
        let list = all()
        UserDefaults.standard.removeObject(forKey: key)
        return list
    }
}
