import Foundation
import SwiftData

/// Builds the app's SwiftData `ModelContainer` so a corrupt / unopenable on-disk
/// store can NEVER crash the app (R29). The local store is only a CACHE — every
/// message and room snapshot re-syncs from the gateway — so the safe recovery for a
/// broken store is to wipe it and start fresh, then let the timeline re-sync.
///
/// Why this exists instead of the bare `.modelContainer(for:)` modifier:
///   • That modifier `fatalError`s if the container can't be created.
///   • SwiftData/CoreData open the SQLite file lazily, so an "couldn't be opened"
///     failure (NSCocoaError 256 / SQLITE_ERROR) surfaces LATER, during a UI-driven
///     fault, as an Objective-C `NSInternalInconsistencyException` that Swift
///     `try/catch` cannot catch — an unrecoverable crash (the R29 production crash).
///
/// The fix forces the open eagerly, in a catchable Swift context (`openAndProbe`),
/// so an unusable store is detected at startup and healed before the UI ever saves.
enum ResilientModelContainer {
    private static let schemaTypes: [any PersistentModel.Type] = [
        ChatMessage.self, MatrixRoomSnapshot.self
    ]

    /// The one container the app uses. Built once, eagerly, at launch.
    static let shared: ModelContainer = make()

    private static func make() -> ModelContainer {
        let schema = Schema(schemaTypes)
        let url = storeURL
        let config = ModelConfiguration(schema: schema, url: url)

        // 1) Normal path: open the store AND prove it reads + writes.
        do {
            return try openAndProbe(schema: schema, config: config)
        } catch {
            // 2) Store is unusable (corrupt / unreadable). It's a cache → wipe + recreate.
            AppLog.log("🗄️ SwiftData store unusable — wiping + recreating (cache; will re-sync): %@",
                       String(describing: error))
            ErrorReporter.capture(error, context: "ResilientModelContainer: store wiped + recreated")
            wipeStoreFiles(at: url)
            if let healed = try? openAndProbe(schema: schema, config: config) {
                return healed
            }
        }

        // 3) Still failing (disk full / permissions) → in-memory so the app runs
        //    unpersisted rather than crash-looping. Re-syncs every launch.
        AppLog.log("🗄️ SwiftData on-disk store unavailable — falling back to in-memory")
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // Creating an in-memory container cannot fail under normal conditions; if it
        // somehow does there is genuinely nothing left to fall back to.
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: schema, configurations: memory)
    }

    /// Open the container and force a real read + write, so an unopenable store throws
    /// HERE (a catchable Swift error) instead of later inside a UI fault (an
    /// uncatchable ObjC exception).
    private static func openAndProbe(schema: Schema, config: ModelConfiguration) throws -> ModelContainer {
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)
        var probe = FetchDescriptor<ChatMessage>()
        probe.fetchLimit = 1
        _ = try context.fetch(probe)
        try context.save()
        return container
    }

    /// SwiftData's default location — `Application Support/default.store` — so an
    /// existing user's store is reused (and, when broken, wiped in place).
    private static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }

    /// Remove the store and every SQLite sidecar so a fresh store starts clean.
    private static func wipeStoreFiles(at url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? fm.removeItem(atPath: url.path + suffix)
        }
    }
}
