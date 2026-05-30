import Foundation
import MatrixRustSDK

/// v2 transport. Owns the matrix-rust-sdk `Client` and `SyncService`, replacing
/// v1's `RelayClient`. `@MainActor @Observable` so SwiftUI binds to
/// `connectionState` directly — no 200 ms polling loop (v1 architecture smell).
@MainActor
@Observable
final class MatrixSession {
    private(set) var connectionState: ConnectionState = .disconnected {
        didSet {
            guard oldValue != connectionState else { return }
            onConnectionStateChange?(connectionState)
        }
    }
    private(set) var userId: String?

    @ObservationIgnored private(set) var client: Client?
    @ObservationIgnored private(set) var syncService: SyncService?
    @ObservationIgnored private(set) var roomListService: RoomListService?
    @ObservationIgnored private let sessionDelegate = MatrixSessionDelegate()

    /// Fired on every connection-state transition. The `MessageTransport`
    /// adapter forwards this to the UI and triggers room binding on connect.
    @ObservationIgnored var onConnectionStateChange: ((ConnectionState) -> Void)?

    // MARK: - Rooms (sessions)

    /// One chat/session the user is in. Drives the sidebar.
    struct RoomSummary: Identifiable, Equatable {
        let id: String        // Matrix room id
        var name: String      // display name (best-effort; falls back to id)
    }

    /// All joined rooms, most-recent first (sliding-sync order). Observable for
    /// the sessions sidebar.
    private(set) var rooms: [RoomSummary] = []

    /// The room currently shown in the chat pane. Switching is local/per-device.
    private(set) var activeRoomId: String?

    /// Fired when `activeRoomId` changes so the transport rebinds its timeline.
    @ObservationIgnored var onActiveRoomChange: ((String?) -> Void)?

    @ObservationIgnored private var roomEntriesResult: RoomListEntriesWithDynamicAdaptersResult?
    @ObservationIgnored private var roomEntriesHandle: TaskHandle?
    @ObservationIgnored private var orderedRoomIds: [String] = []

    /// True if a paired session is persisted on disk (drives launch routing).
    var isPaired: Bool { MatrixCredentialStore.load() != nil }

    // MARK: - Pairing

    /// Full pairing: redeem the code at the registrar → restore the returned
    /// credentials into a live client and start syncing.
    func pair(code: String) async {
        connectionState = .connecting
        do {
            let env = MatrixEnvironment.current
            let session = try await MatrixPairing.redeem(
                code: code,
                deviceName: Self.deviceDisplayName,
                registrarBaseURL: env.registrarBaseURL,
                homeserverURL: env.homeserverURL
            )
            let passphrase = MatrixCredentialStore.newStorePassphrase()
            try MatrixCredentialStore.save(.init(session: session, storePassphrase: passphrase))
            try await startClient(session: session)
        } catch {
            connectionState = .failed(error.localizedDescription)
            AppLog.log("❌ Matrix pairing failed: \(error)")
        }
    }

    // MARK: - Connect / disconnect

    /// Restore a previously-paired session on launch.
    func connect() async {
        guard let stored = MatrixCredentialStore.load() else {
            connectionState = .disconnected
            return
        }
        connectionState = .connecting
        do {
            try await startClient(session: stored.session)
        } catch {
            connectionState = .failed(error.localizedDescription)
            AppLog.log("❌ Matrix connect failed: \(error)")
        }
    }

    /// Tear down the live client/sync without forgetting credentials.
    func disconnect() async {
        roomEntriesHandle?.cancel()
        roomEntriesHandle = nil
        roomEntriesResult = nil
        orderedRoomIds = []
        rooms = []
        activeRoomId = nil
        await syncService?.stop()
        syncService = nil
        client = nil
        connectionState = .disconnected
    }

    /// Tear down and forget credentials (user-initiated sign out).
    func signOut() async {
        await disconnect()
        MatrixCredentialStore.delete()
        userId = nil
    }

    // MARK: - Internals

    private func startClient(session: Session) async throws {
        let env = MatrixEnvironment.current
        // TODO(v2): encrypt the SQLite store at rest via `sqliteStore(config:)`
        // using the persisted `storePassphrase`. For now `sessionPaths` +
        // on-device file protection cover at-rest.
        let client = try await ClientBuilder()
            .homeserverUrl(url: session.homeserverUrl)
            .sessionPaths(dataPath: env.sessionDataPath, cachePath: env.sessionCachePath)
            .setSessionDelegate(sessionDelegate: sessionDelegate)
            .autoEnableCrossSigning(autoEnableCrossSigning: true)
            .autoEnableBackups(autoEnableBackups: true)
            .build()

        try await client.restoreSession(session: session)

        let syncService = try await client.syncService().finish()
        await syncService.start()

        self.client = client
        self.syncService = syncService
        self.roomListService = syncService.roomListService()
        self.userId = session.userId
        self.connectionState = .connected
        AppLog.log("✅ Matrix client connected as \(session.userId)")

        await startRoomList()
    }

    // MARK: - Room list

    /// Switch the active session (local act; no protocol event). Rebinds the
    /// transport timeline via `onActiveRoomChange`.
    func selectRoom(_ id: String) {
        guard activeRoomId != id else { return }
        activeRoomId = id
        onActiveRoomChange?(id)
    }

    /// Request a brand-new session. Per protocol §5 only the plugin creates
    /// sessions — the device sends a `chat4000.command` `session.new` into the
    /// per-plugin control room. Control-room identification isn't defined in the
    /// protocol yet, so this is a stub pending that decision.
    func requestNewSession() {
        AppLog.log("🆕 requestNewSession — TODO: send session.new to the control room (scheme undefined in protocol)")
    }

    private func startRoomList() async {
        guard roomEntriesResult == nil, let rls = roomListService else { return }
        do {
            let roomList = try await rls.allRooms()
            let observer = RoomEntriesObserver { [weak self] updates in
                Task { @MainActor in self?.applyRoomEntries(updates) }
            }
            let result = roomList.entriesWithDynamicAdapters(pageSize: 200, listener: observer)
            roomEntriesResult = result
            roomEntriesHandle = result.entriesStream()
            _ = result.controller().setFilter(kind: .all(filters: [.nonLeft]))
        } catch {
            AppLog.log("❌ Matrix room-list start failed: \(error)")
        }
    }

    private func applyRoomEntries(_ updates: [RoomListEntriesUpdate]) {
        for update in updates {
            switch update {
            case .append(let values): orderedRoomIds.append(contentsOf: values.map { $0.id() })
            case .pushBack(let value): orderedRoomIds.append(value.id())
            case .pushFront(let value): orderedRoomIds.insert(value.id(), at: 0)
            case .insert(let index, let value):
                orderedRoomIds.insert(value.id(), at: min(Int(index), orderedRoomIds.count))
            case .set(let index, let value):
                if Int(index) < orderedRoomIds.count { orderedRoomIds[Int(index)] = value.id() }
            case .remove(let index):
                if Int(index) < orderedRoomIds.count { orderedRoomIds.remove(at: Int(index)) }
            case .popFront: if !orderedRoomIds.isEmpty { orderedRoomIds.removeFirst() }
            case .popBack: if !orderedRoomIds.isEmpty { orderedRoomIds.removeLast() }
            case .truncate(let length): orderedRoomIds = Array(orderedRoomIds.prefix(Int(length)))
            case .reset(let values): orderedRoomIds = values.map { $0.id() }
            case .clear: orderedRoomIds = []
            }
        }

        // Rebuild summaries. TODO(v2): resolve display names (Room.displayName)
        // and distinguish control vs session rooms per the protocol's space model.
        rooms = orderedRoomIds.map { RoomSummary(id: $0, name: $0) }

        // Default to the most-recent room if none selected yet.
        if activeRoomId == nil, let first = orderedRoomIds.first {
            activeRoomId = first
            onActiveRoomChange?(first)
        }
    }

    private static var deviceDisplayName: String {
        #if os(macOS)
        "chat4000 Mac"
        #else
        "chat4000 iPhone"
        #endif
    }
}

/// Bridges the Sendable SDK room-list callback onto the main actor.
private final class RoomEntriesObserver: RoomListEntriesListener, @unchecked Sendable {
    private let handler: @Sendable ([RoomListEntriesUpdate]) -> Void
    init(_ handler: @escaping @Sendable ([RoomListEntriesUpdate]) -> Void) { self.handler = handler }
    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) { handler(roomEntriesUpdate) }
}
