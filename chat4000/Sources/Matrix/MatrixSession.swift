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

    /// The per-plugin control room (`chat4000.room_kind == "control"`, protocol
    /// §5). Where `session.new`/`rename`/`archive` go. Hidden from the sidebar.
    private(set) var controlRoomId: String?

    @ObservationIgnored private var roomEntriesResult: RoomListEntriesWithDynamicAdaptersResult?
    @ObservationIgnored private var roomEntriesHandle: TaskHandle?
    @ObservationIgnored private var orderedRoomIds: [String] = []
    /// Cached `chat4000.room_kind` per room id (immutable once set).
    @ObservationIgnored private var roomKindCache: [String: String] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var homeserverURL: String?
    /// Set after a `session.new`; the next freshly-appearing session room is
    /// auto-opened so "New chat" lands the user in the new conversation.
    @ObservationIgnored private var pendingAutoOpen = false
    /// Exact room id from a `session.new` `command_result` — opened precisely
    /// once it shows up in the room list.
    @ObservationIgnored private var autoOpenRoomId: String?
    @ObservationIgnored private var controlTimeline: Timeline?
    @ObservationIgnored private var controlTimelineHandle: TaskHandle?
    @ObservationIgnored private var seenControlEvents: Set<String> = []
    @ObservationIgnored private var pushTokenObserver: NSObjectProtocol?

    init() {
        // Re-register the APNs pusher whenever the device token changes.
        pushTokenObserver = NotificationCenter.default.addObserver(
            forName: PushNotificationManager.deviceTokenDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let token = PushNotificationManager.shared.deviceToken else { return }
                await self.registerPushToken(token)
            }
        }
    }

    /// Last failed control command the plugin rejected (UI can surface it).
    private(set) var lastCommandError: String?
    /// Human-readable result of the most recent `plugin.update_check`/`update`.
    private(set) var lastPluginUpdateStatus: String?

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
        controlTimelineHandle?.cancel()
        controlTimelineHandle = nil
        controlTimeline = nil
        controlRoomId = nil
        seenControlEvents = []
        autoOpenRoomId = nil
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
        // Kept for raw homeserver reads the SDK doesn't expose (room_kind state).
        self.accessToken = session.accessToken
        self.homeserverURL = session.homeserverUrl
        self.connectionState = .connected
        AppLog.log("✅ Matrix client connected as \(session.userId)")

        if let token = PushNotificationManager.shared.deviceToken {
            await registerPushToken(token)
        }
        await startRoomList()
    }

    /// Register this device's APNs token as a Matrix pusher so the homeserver
    /// wakes it for offline messages (protocol F). `data.url` points at the
    /// notification service (homeserver-internal); `app_id` is our bundle id,
    /// which is what the notification service routes on (F.1).
    func registerPushToken(_ token: String) async {
        guard let client else { return }
        let appId = Bundle.main.bundleIdentifier ?? "com.neonnode.chat94app"
        do {
            try await client.setPusher(
                identifiers: PusherIdentifiers(pushkey: token, appId: appId),
                kind: .http(data: HttpPusherData(
                    url: MatrixEnvironment.current.notificationPushURL,
                    format: .eventIdOnly,
                    defaultPayload: nil
                )),
                appDisplayName: "chat4000",
                deviceDisplayName: Self.deviceDisplayName,
                profileTag: nil,
                lang: "en"
            )
            AppLog.log("✅ APNs pusher registered (app_id=\(appId))")
        } catch {
            AppLog.log("❌ setPusher failed: \(error)")
        }
    }

    // MARK: - Room list

    /// Switch the active session (local act; no protocol event). Rebinds the
    /// transport timeline via `onActiveRoomChange`.
    func selectRoom(_ id: String) {
        guard activeRoomId != id else { return }
        activeRoomId = id
        onActiveRoomChange?(id)
    }

    // MARK: - Control-room commands (protocol §5)

    /// Ask the plugin to create a new session. The new room arrives via sync and
    /// is auto-opened (`pendingAutoOpen`).
    func requestNewSession(title: String? = nil) {
        var fields: [String: Any] = ["command": "session.new", "agent_id": "main"]
        if let title, !title.isEmpty { fields["title"] = String(title.prefix(255)) }
        sendControlCommand(fields)
        pendingAutoOpen = true
    }

    func renameSession(roomId: String, title: String) {
        sendControlCommand(["command": "session.rename", "room_id": roomId, "title": String(title.prefix(255))])
    }

    func archiveSession(roomId: String) {
        sendControlCommand(["command": "session.archive", "room_id": roomId])
    }

    /// Mute / unmute a room via the homeserver's notification settings
    /// (protocol D.2: a room push rule). Muted rooms never wake the user.
    func muteRoom(_ roomId: String) {
        guard let client else { return }
        Task {
            let settings = await client.getNotificationSettings()
            try? await settings.setRoomNotificationMode(roomId: roomId, mode: .mute)
        }
    }

    func unmuteRoom(_ roomId: String) {
        guard let client else { return }
        Task {
            let settings = await client.getNotificationSettings()
            try? await settings.unmuteRoom(roomId: roomId, isEncrypted: true, isOneToOne: false)
        }
    }

    /// Plugin self-update (§5, owner-gated server-side). Fire-and-forget: the
    /// plugin's `command_result` is not surfaced because the SDK doesn't expose
    /// custom message fields (and the event is encrypted, so no raw read).
    func checkPluginUpdate() { sendControlCommand(["command": "plugin.update_check"]) }
    func applyPluginUpdate() { sendControlCommand(["command": "plugin.update", "restart": true]) }

    /// Send a `chat4000.command` `m.room.message` into the control room.
    private func sendControlCommand(_ fields: [String: Any]) {
        guard let rls = roomListService, let controlRoomId,
              let room = try? rls.room(roomId: controlRoomId) else {
            AppLog.log("⚙️ control command dropped — no control room identified yet")
            return
        }
        var body: [String: Any] = ["msgtype": "chat4000.command"]
        body.merge(fields) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let json = String(data: data, encoding: .utf8) else { return }
        Task {
            do { try await room.sendRaw(eventType: "m.room.message", content: json) }
            catch { AppLog.log("⚙️ control command send failed: \(error)") }
        }
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

        scheduleRoomRefresh()
    }

    /// Debounced rebuild of `rooms` — resolves display names and classifies
    /// control vs session rooms (protocol §5 `chat4000.room_kind`).
    private func scheduleRoomRefresh() {
        refreshTask?.cancel()
        let ids = orderedRoomIds
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            await self.rebuildRooms(ids: ids)
        }
    }

    private func rebuildRooms(ids: [String]) async {
        guard let rls = roomListService else { return }
        let knownIds = Set(rooms.map(\.id))
        var sessions: [RoomSummary] = []
        var foundControl: String?
        for id in ids {
            guard let room = try? rls.room(roomId: id) else { continue }
            let info = try? await room.roomInfo()
            if info?.isSpace == true { continue }        // hide the plugin's space
            if await roomKind(id: id) == "control" {     // hide the control room
                foundControl = id
                continue
            }
            let name = info?.displayName ?? info?.rawName ?? Self.shortId(id)
            sessions.append(RoomSummary(id: id, name: name))
        }
        rooms = sessions
        if let foundControl {
            controlRoomId = foundControl
            if controlTimeline == nil { await bindControlTimeline(foundControl) }
        }

        // Open the exact room a `session.new` result named, once it's in the list.
        if let target = autoOpenRoomId, sessions.contains(where: { $0.id == target }) {
            autoOpenRoomId = nil
            pendingAutoOpen = false
            activeRoomId = target
            onActiveRoomChange?(target)
        } else if pendingAutoOpen, let fresh = sessions.first(where: { !knownIds.contains($0.id) }) {
            // Fallback if the result wasn't parsed: jump to the freshest room.
            pendingAutoOpen = false
            activeRoomId = fresh.id
            onActiveRoomChange?(fresh.id)
        } else if activeRoomId == nil, let first = sessions.first {
            activeRoomId = first.id
            onActiveRoomChange?(first.id)
        }
    }

    // MARK: - Control-room results (parse command_result via raw event JSON)

    private func bindControlTimeline(_ roomId: String) async {
        guard let rls = roomListService, let room = try? rls.room(roomId: roomId),
              let timeline = try? await room.timeline() else { return }
        controlTimeline = timeline
        let observer = ControlTimelineObserver { [weak self] diffs in
            Task { @MainActor in self?.handleControlDiffs(diffs) }
        }
        controlTimelineHandle = await timeline.addListener(listener: observer)
        AppLog.log("✅ Matrix observing control room \(roomId)")
    }

    private func handleControlDiffs(_ diffs: [TimelineDiff]) {
        for diff in diffs {
            let items: [TimelineItem]
            switch diff {
            case .append(let v): items = v
            case .reset(let v): items = v
            case .pushBack(let v), .pushFront(let v), .insert(_, let v), .set(_, let v): items = [v]
            default: continue
            }
            items.forEach(processControlItem)
        }
    }

    private func processControlItem(_ item: TimelineItem) {
        guard let event = item.asEvent(),
              case let .eventId(eid) = event.eventOrTransactionId,
              !seenControlEvents.contains(eid),
              // The SDK drops custom message fields, so read the raw decrypted
              // event JSON (lazyProvider.latestJson) and parse it ourselves.
              let json = event.lazyProvider.latestJson(),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [String: Any],
              content["msgtype"] as? String == "chat4000.command_result"
        else { return }
        seenControlEvents.insert(eid)
        handleCommandResult(content)
    }

    private func handleCommandResult(_ c: [String: Any]) {
        let command = c["command"] as? String ?? ""
        let ok = c["ok"] as? Bool ?? false
        let error = c["error"] as? String
        switch command {
        case "session.new":
            if ok, let roomId = c["room_id"] as? String {
                autoOpenRoomId = roomId
                scheduleRoomRefresh()
            } else {
                lastCommandError = error ?? "Could not create a new session."
            }
        case "session.rename", "session.archive":
            if !ok { lastCommandError = error ?? "\(command) failed." }
        case "plugin.update_check":
            if ok, let latest = c["latest_version"] as? String {
                let updatable = (c["updatable"] as? Bool) ?? false
                lastPluginUpdateStatus = updatable ? "Update available: \(latest)" : "Plugin up to date (\(latest))"
            } else {
                lastPluginUpdateStatus = error ?? "Update check failed."
            }
        case "plugin.update":
            if ok, let to = c["to_version"] as? String {
                lastPluginUpdateStatus = "Updated to \(to)"
            } else {
                lastPluginUpdateStatus = error ?? "Plugin update failed."
            }
        default:
            break
        }
    }

    /// Read `chat4000.room_kind` via a raw homeserver state GET. The high-level
    /// SDK doesn't expose custom state-event content, but we hold the device
    /// access token (SDK-direct), so we read it ourselves. Cached per room.
    private func roomKind(id: String) async -> String? {
        if let cached = roomKindCache[id] { return cached }
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let token = accessToken, let hs = homeserverURL,
              let encoded = id.addingPercentEncoding(withAllowedCharacters: unreserved),
              let url = URL(string: "\(hs)/_matrix/client/v3/rooms/\(encoded)/state/chat4000.room_kind/")
        else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = obj["kind"] as? String
        else { return nil }
        roomKindCache[id] = kind
        return kind
    }

    private static func shortId(_ id: String) -> String {
        let trimmed = id.hasPrefix("!") ? String(id.dropFirst()) : id
        return trimmed.split(separator: ":").first.map(String.init) ?? id
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

/// Bridges the Sendable SDK control-room timeline callback onto the main actor.
private final class ControlTimelineObserver: TimelineListener, @unchecked Sendable {
    private let handler: @Sendable ([TimelineDiff]) -> Void
    init(_ handler: @escaping @Sendable ([TimelineDiff]) -> Void) { self.handler = handler }
    func onUpdate(diff: [TimelineDiff]) { handler(diff) }
}
