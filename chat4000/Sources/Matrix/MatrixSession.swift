import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// One decrypted (or cleartext) room event handed to the timeline mapper.
/// `outer` is the envelope (`event_id`/`sender`/`origin_server_ts`, and the
/// cleartext `m.relates_to` / `chat4000.push` for `m.room.encrypted`); `clear`
/// is the decrypted inner event JSON (`type`/`content`), or nil for a cleartext
/// event or one we couldn't decrypt yet.
struct DecryptedRoomEvent: Sendable {
    let outer: SyncEvent
    let clear: String?
    let isOwn: Bool
}

/// v2 transport hub. Owns the native `GatewayClient` (WS frame protocol, D.1)
/// and the standalone `CryptoEngine` (Olm/Megolm). Replaces the matrix-rust-sdk
/// `Client`/`SyncService`/`Timeline` stack — the homeserver has no public
/// hostname, so the SDK's HTTP mode is impossible (protocol D.3). `@MainActor
/// @Observable` so SwiftUI binds to `connectionState`/`rooms` directly.
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

    /// First-run setup progress, surfaced to the UI as a step indicator until the
    /// workspace is usable. Monotonic-ish: connect → sync → join the plugin's
    /// invite → wait for the plugin's control room → ready.
    enum SetupPhase: Int, Sendable {
        case connecting, syncing, joiningWorkspace, waitingForPlugin, ready
        var label: String {
            switch self {
            case .connecting: return "Connecting…"
            case .syncing: return "Syncing…"
            case .joiningWorkspace: return "Joining your workspace…"
            case .waitingForPlugin: return "Waiting for your plugin…"
            case .ready: return "Ready"
            }
        }
        /// 0…1 for a progress bar.
        var progress: Double { Double(rawValue) / Double(SetupPhase.ready.rawValue) }
    }
    private(set) var setupPhase: SetupPhase = .connecting

    @ObservationIgnored var onConnectionStateChange: ((ConnectionState) -> Void)?

    // MARK: - Rooms (sessions)

    struct RoomSummary: Identifiable, Equatable {
        let id: String
        var name: String
    }

    /// All joined session rooms, in first-seen order. Drives the sidebar.
    private(set) var rooms: [RoomSummary] = []
    private(set) var activeRoomId: String?
    @ObservationIgnored var onActiveRoomChange: ((String?) -> Void)?

    /// The per-plugin control room (`chat4000.room_kind == "control"`, E). Hidden
    /// from the sidebar; where session/plugin commands go.
    private(set) var controlRoomId: String?

    private(set) var lastCommandError: String?
    private(set) var lastPluginUpdateStatus: String?

    /// Per-event delivery to the timeline mapper (active room only, plus replay
    /// on room switch). `live` is false for backfilled/replayed history.
    @ObservationIgnored var onRoomEvent: ((_ roomId: String, _ event: DecryptedRoomEvent, _ live: Bool) -> Void)?
    /// Latest `chat4000.status` for the active room (drives the busy indicator).
    @ObservationIgnored var onActiveRoomStatus: ((_ state: String) -> Void)?
    /// An outbound message's send completed → its homeserver event_id (for
    /// correlating later read receipts). `localId` is what `sendText`'s caller used.
    @ObservationIgnored var onSentEventId: ((_ localId: String, _ eventId: String) -> Void)?
    /// A peer (the plugin) read up to `eventId` → drives the "read" tick.
    @ObservationIgnored var onReadReceipt: ((_ eventId: String) -> Void)?

    // MARK: - Internals

    @ObservationIgnored private var gateway: GatewayClient?
    @ObservationIgnored private var crypto: CryptoEngine?
    @ObservationIgnored private var creds: MatrixCredentialStore.Stored?
    /// HTTP base for authenticated media (protocol D.3), derived from the
    /// gateway URL on connect.
    @ObservationIgnored private var mediaBaseURL: String?

    @ObservationIgnored private var roomOrder: [String] = []
    @ObservationIgnored private var roomMembers: [String: [String]] = [:]
    @ObservationIgnored private var roomNames: [String: String] = [:]
    @ObservationIgnored private var spaceRooms: Set<String> = []
    @ObservationIgnored private var encryptedRooms: Set<String> = []
    /// Rooms we've already fired a join for (invite auto-accept), so we don't
    /// re-POST /join on every sync while the join settles.
    @ObservationIgnored private var joinedInviteAttempts: Set<String> = []
    /// Event ids we've already gossip-requested a key for, so we don't re-request
    /// the same undecryptable event on every sync.
    @ObservationIgnored private var requestedKeyFor: Set<String> = []
    /// Encrypted events we couldn't decrypt yet, kept so we can retry once the
    /// missing Megolm key arrives (it won't re-appear in a later sync timeline).
    @ObservationIgnored private var undecrypted: [String: (roomId: String, outer: SyncEvent)] = [:]
    @ObservationIgnored private var trackedUsers: Set<String> = []
    @ObservationIgnored private var seenEventIds: Set<String> = []
    @ObservationIgnored private var roomEventCache: [String: [DecryptedRoomEvent]] = [:]
    @ObservationIgnored private var lastStatusByRoom: [String: String] = [:]
    @ObservationIgnored private var roomKinds: [String: String] = [:]

    @ObservationIgnored private var pendingAutoOpen = false
    @ObservationIgnored private var autoOpenRoomId: String?
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var pushTokenObserver: NSObjectProtocol?
    /// Continuations awaiting the next processed sync (background-wake drain).
    @ObservationIgnored private var syncWaiters: [CheckedContinuation<Void, Never>] = []
    /// Local notifications posted in the current sync batch (flood guard).
    @ObservationIgnored private var backgroundNotifyCount = 0

    init() {
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

    /// True if paired credentials are persisted (drives launch routing).
    var isPaired: Bool { MatrixCredentialStore.load() != nil }

    // MARK: - Pairing / connect

    func pair(code: String) async {
        connectionState = .connecting
        do {
            let env = MatrixEnvironment.current
            let redeemed = try await MatrixPairing.redeem(
                code: code,
                deviceName: Self.deviceDisplayName,
                registrarBaseURL: env.registrarBaseURL
            )
            let stored = MatrixCredentialStore.Stored(
                accessToken: redeemed.accessToken,
                userId: redeemed.userId,
                deviceId: redeemed.deviceId,
                gatewayURL: redeemed.gatewayUrl
            )
            try MatrixCredentialStore.save(stored)
            // A fresh pairing is a brand-new device with new keys; discard any
            // crypto store left by a previous pairing so the new device doesn't
            // inherit a stale key DB (different user / device_id).
            Self.wipeCryptoStore()
            try await startClient(stored)
        } catch .cancelled {
            // Benign — a torn-down pairing flow. Don't surface as a failure.
            AppLog.log("⚙️ Matrix pairing cancelled")
        } catch {
            // Expected, user-facing pairing failures (bad/expired code, etc.) and
            // any classified boundary failure. Reporting (if warranted) already
            // happened at the boundary that produced the AppError.
            connectionState = .failed(error.message)
            AppLog.log("❌ Matrix pairing failed: \(error)")
        }
    }

    /// Restore a paired session on launch / foreground. No-op if already up.
    func connect() async {
        if gateway != nil, connectionState == .connected { return }
        guard let stored = MatrixCredentialStore.load() else {
            connectionState = .disconnected
            return
        }
        connectionState = .connecting
        do {
            try await startClient(stored)
        } catch .cancelled {
            AppLog.log("⚙️ Matrix connect cancelled")
        } catch {
            // Already classified (and, if unexpected, reported) at the boundary.
            connectionState = .failed(error.message)
            AppLog.log("❌ Matrix connect failed: \(error)")
        }
    }

    func disconnect() async {
        gateway?.disconnect()
        gateway = nil
        crypto = nil
        resetSessionState()
        connectionState = .disconnected
    }

    func signOut() async {
        let uid = userId
        await disconnect()
        MatrixCredentialStore.delete()
        Self.wipeCryptoStore()
        if let uid { UserDefaults.standard.removeObject(forKey: Self.syncPosKey(uid)) }
        userId = nil
    }

    /// Delete the standalone crypto store on disk. A fresh pairing (new device,
    /// new keys) must not inherit a previous pairing's key DB. The store is
    /// unencrypted (CryptoEngine passes no passphrase); the dir is recreated
    /// empty by `cryptoStorePath` when the next client starts.
    private static func wipeCryptoStore() {
        try? FileManager.default.removeItem(atPath: MatrixEnvironment.current.cryptoStorePath)
    }

    private func resetSessionState() {
        roomOrder = []
        roomMembers = [:]
        roomNames = [:]
        spaceRooms = []
        encryptedRooms = []
        joinedInviteAttempts = []
        trackedUsers = []
        seenEventIds = []
        roomEventCache = [:]
        lastStatusByRoom = [:]
        roomKinds = [:]
        rooms = []
        activeRoomId = nil
        controlRoomId = nil
        autoOpenRoomId = nil
        pendingAutoOpen = false
        requestedKeyFor = []
        undecrypted = [:]
        setupPhase = .connecting
    }

    private func startClient(_ stored: MatrixCredentialStore.Stored) async throws(AppError) {
        guard let url = URL(string: stored.gatewayURL) else {
            throw AppError.invalidConfiguration("gateway URL")
        }
        creds = stored
        mediaBaseURL = MatrixEnvironment.mediaBaseURL(fromGatewayURL: stored.gatewayURL)
        let identity = GatewayClient.Identity(
            appId: Bundle.main.bundleIdentifier ?? "com.neonnode.chat94app",
            clientVersion: AppRegistrationIdentity.currentAppVersion,
            platform: Self.platform,
            releaseChannel: VersionPolicyManager.releaseChannel
        )
        let gateway = GatewayClient(url: url, accessToken: stored.accessToken, identity: identity)
        gateway.onReauthNeeded = { [weak self] in
            guard let self, let token = self.creds?.accessToken else { return }
            self.gateway?.reauth(token: token)
        }
        gateway.onSync = { [weak self] frame in
            Task { @MainActor in await self?.handleSync(frame) }
        }
        gateway.onClosed = { [weak self] in
            Task { @MainActor in await self?.handleSocketClosed() }
        }

        let auth = try await gateway.connect()
        let crypto = try CryptoEngine(
            userId: auth.userId,
            deviceId: auth.deviceId,
            storePath: MatrixEnvironment.current.cryptoStorePath,
            gateway: gateway
        )

        self.gateway = gateway
        self.crypto = crypto
        self.userId = auth.userId
        self.reconnectAttempts = 0
        self.connectionState = .connected
        if setupPhase.rawValue < SetupPhase.syncing.rawValue { setupPhase = .syncing }
        AppLog.log("✅ Matrix gateway connected as \(auth.userId) device \(auth.deviceId)")

        // Publish our device keys / one-time keys before syncing.
        try await crypto.runOutgoingRequests()
        // Resume from the device's last durably-acked position (protocol D.1):
        // the device is the source of truth for `pos`, so to-device room keys we
        // hadn't persisted are still on the homeserver and get re-delivered.
        let resumePos = Self.loadSyncPos(userId: auth.userId)
        gateway.startSync(body: SlidingSync.requestBody(), pos: resumePos)

        if let token = PushNotificationManager.shared.deviceToken {
            await registerPushToken(token)
        }
    }

    private func handleSocketClosed() async {
        guard connectionState == .connected else { return }
        connectionState = .reconnecting
        reconnectAttempts += 1
        let delay = min(60, Int(pow(2.0, Double(min(reconnectAttempts, 6)))))
        AppLog.log("🔌 gateway closed — reconnecting in \(delay)s (attempt \(reconnectAttempts))")
        try? await Task.sleep(for: .seconds(delay))
        guard connectionState == .reconnecting, let stored = creds else { return }
        gateway = nil
        crypto = nil
        do {
            try await startClient(stored)
        } catch .cancelled {
            AppLog.log("⚙️ reconnect cancelled")
        } catch {
            // Classified (and, if unexpected, reported) at the boundary already.
            AppLog.log("❌ reconnect failed: \(error)")
            await handleSocketClosed()
        }
    }

    // MARK: - Sync handling

    private func handleSync(_ frame: [String: Any]) async {
        backgroundNotifyCount = 0
        let sync = SyncModel.parse(frame)
        AppLog.log("🔄 sync pos=%@ rooms=%d to_device=%d", sync.pos ?? "nil", sync.rooms.count, sync.toDevice.count)
        for r in sync.rooms {
            AppLog.log("🏠 room %@ kind=%@ space=%@ invite=%@ enc=%@ members=%d tl=%d",
                       r.id, r.roomKind ?? "nil", String(r.isSpace), String(r.isInvite),
                       String(r.isEncrypted), r.members.count, r.timeline.count)
        }
        // Feed e2ee state (to-device room keys, device lists, OTK counts) and
        // drain outgoing crypto requests BEFORE decrypting room events.
        do { try await crypto?.processSync(sync) } catch {
            ErrorReporter.capture(error, context: "MatrixSession.processSync")
            AppLog.log("⚙️ crypto.processSync failed: \(error)")
        }

        for room in sync.rooms { await processRoom(room) }
        retryUndecrypted()
        rebuildRoomList()
        applyAutoOpen()
        updateSetupPhase()

        // Read receipts from anyone but us → advance our "read" ticks.
        for receipt in sync.receipts where receipt.userId != userId {
            AppLog.debug("👁️ read receipt from %@ up to %@", receipt.userId, receipt.eventId)
            onReadReceipt?(receipt.eventId)
        }

        // Durable-ack the cursor (protocol D.1, "Sync cursor & key delivery"):
        // processSync persisted the to-device Megolm keys + crypto state and the
        // dispatch above persisted messages, so it's now safe to let the gateway
        // advance upstream (and the homeserver delete the acked to-device). The
        // gateway holds the cursor until this arrives — without it, sync never
        // advances and no new messages are delivered.
        if let pos = sync.pos {
            Self.saveSyncPos(pos, userId: userId)
            gateway?.syncAck(pos: pos)
        }
        resumeSyncWaiters()
    }

    private func processRoom(_ room: SyncRoom) async {
        // Auto-accept invites: a room we're invited to (the plugin's control
        // room / space / session) only appears in sliding sync as `invite`; the
        // list shows joined rooms, so we'd never see it with full state. Join it
        // and let the next sync re-deliver it joined (with chat4000.room_kind etc.).
        if isInvited(room), joinedInviteAttempts.insert(room.id).inserted {
            AppLog.log("📨 auto-joining invited room %@", room.id)
            await joinRoom(room.id)
            return
        }

        if !roomOrder.contains(room.id) { roomOrder.append(room.id) }
        if let kind = room.roomKind { roomKinds[room.id] = kind }
        if let name = room.name, !name.isEmpty { roomNames[room.id] = name }
        if room.isSpace { spaceRooms.insert(room.id); return } // the plugin's space; never a chat

        // Membership → crypto: mark encrypted + track + remember recipients.
        // These were silently `try?`'d; a failure here breaks key sharing
        // (no algorithm set / untracked users → no Olm session → UTD), so log it.
        if room.isEncrypted, !encryptedRooms.contains(room.id) {
            do { try crypto?.markRoomEncrypted(room.id); encryptedRooms.insert(room.id) } catch {
                ErrorReporter.capture(error, context: "MatrixSession.markRoomEncrypted")
                AppLog.log("⚙️ markRoomEncrypted failed for %@: %@", room.id, error.localizedDescription)
            }
        }
        if !room.members.isEmpty {
            roomMembers[room.id] = room.members
            let newUsers = room.members.filter { !trackedUsers.contains($0) }
            if !newUsers.isEmpty {
                do {
                    try crypto?.updateTrackedUsers(newUsers)
                    trackedUsers.formUnion(newUsers)
                    AppLog.debug("🔑 tracking %d new user(s) for key queries: %@", newUsers.count, newUsers.joined(separator: ","))
                } catch {
                    ErrorReporter.capture(error, context: "MatrixSession.updateTrackedUsers")
                    AppLog.log("⚙️ updateTrackedUsers failed for %@: %@", room.id, error.localizedDescription)
                }
            }
        }

        let isControl = roomKinds[room.id] == "control"
        let isActive = activeRoomId == room.id
        AppLog.debug("🏠· process %@ control=%@ active=%@ timeline=%d",
                     room.id, String(isControl), String(isActive), room.timeline.count)

        for outer in room.timeline {
            guard let eid = outer.eventId, !seenEventIds.contains(eid) else { continue }
            seenEventIds.insert(eid)

            let clear: String?
            if outer.type == "m.room.encrypted" {
                do {
                    clear = try crypto?.decrypt(eventJSON: outer.rawJSON, roomId: room.id)
                    if clear != nil { AppLog.debug("🔓 decrypted %@ in %@", eid, room.id) }
                } catch {
                    clear = nil
                    AppLog.log("🔒 decrypt failed %@ in %@: %@ — requesting key", eid, room.id, error.localizedDescription)
                    // Buffer for retry once the key arrives (the event won't be
                    // in a future sync timeline), and gossip-request it once.
                    undecrypted[eid] = (room.id, outer)
                    if requestedKeyFor.insert(eid).inserted {
                        let raw = outer.rawJSON, rid = room.id
                        Task { [weak self] in try? await self?.crypto?.requestRoomKey(forEvent: raw, roomId: rid) }
                    }
                }
            } else {
                clear = outer.rawJSON
            }

            if isControl {
                AppLog.debug("🎛️ control event %@ → parse command_result", eid)
                handleControlEvent(clear: clear)
                continue
            }

            let event = DecryptedRoomEvent(outer: outer, clear: clear, isOwn: outer.sender == userId)
            roomEventCache[room.id, default: []].append(event)
            if isActive { onRoomEvent?(room.id, event, true) }
            if isBackgrounded, !event.isOwn { maybePostBackgroundNotification(outer: outer, clear: clear) }
        }

        // chat4000.status (cleartext state) → busy indicator, active room only.
        if isActive, !isControl, let state = room.statusState, lastStatusByRoom[room.id] != state {
            lastStatusByRoom[room.id] = state
            onActiveRoomStatus?(state)
        }
    }

    /// Re-decrypt buffered UTD events — a sync may have just delivered the key
    /// (via gossip response or a fresh share). On success, deliver them like any
    /// freshly-synced event (control-room results are parsed; session events go
    /// to the active room's mapper).
    private func retryUndecrypted() {
        guard !undecrypted.isEmpty, let crypto else { return }
        for (eid, entry) in undecrypted {
            guard let clear = try? crypto.decrypt(eventJSON: entry.outer.rawJSON, roomId: entry.roomId) else { continue }
            undecrypted.removeValue(forKey: eid)
            AppLog.log("🔓 late-decrypted %@ in %@", eid, entry.roomId)
            if roomKinds[entry.roomId] == "control" {
                handleControlEvent(clear: clear)
                continue
            }
            let event = DecryptedRoomEvent(outer: entry.outer, clear: clear, isOwn: entry.outer.sender == userId)
            roomEventCache[entry.roomId, default: []].append(event)
            if activeRoomId == entry.roomId { onRoomEvent?(entry.roomId, event, false) }
        }
    }

    private func rebuildRoomList() {
        if controlRoomId == nil {
            controlRoomId = roomOrder.first { roomKinds[$0] == "control" }
        }
        // Sidebar = every joined room except the plugin's space and the control
        // room (protocol E). A room with no `chat4000.room_kind` is a session.
        rooms = roomOrder.compactMap { id in
            if spaceRooms.contains(id) { return nil }
            if roomKinds[id] == "control" { return nil }
            return RoomSummary(id: id, name: roomNames[id] ?? Self.shortId(id))
        }
        AppLog.log("📋 rebuilt: ordered=%d sessions=%d spaces=%d control=%@",
                   roomOrder.count, rooms.count, spaceRooms.count, controlRoomId ?? "nil")
    }

    /// Recompute the first-run progress phase from current room state.
    private func updateSetupPhase() {
        if controlRoomId != nil || !rooms.isEmpty {
            setupPhase = .ready
        } else if !joinedInviteAttempts.isEmpty {
            setupPhase = .joiningWorkspace          // joined an invite; awaiting the joined re-sync
        } else {
            setupPhase = .waitingForPlugin          // connected + synced, but no invite yet
        }
    }

    private func applyAutoOpen() {
        if let target = autoOpenRoomId, rooms.contains(where: { $0.id == target }) {
            autoOpenRoomId = nil
            pendingAutoOpen = false
            selectRoom(target)
        } else if activeRoomId == nil, let first = rooms.first {
            selectRoom(first.id)
        }
    }

    // MARK: - Room selection (local; replays the room's cached events)

    func selectRoom(_ id: String) {
        guard activeRoomId != id else { return }
        activeRoomId = id
        onActiveRoomChange?(id)
        for event in roomEventCache[id] ?? [] {
            onRoomEvent?(id, event, false)
        }
        if let state = lastStatusByRoom[id] { onActiveRoomStatus?(state) }
    }

    // MARK: - Sending (called by the transport)

    /// Encrypt + send a plain-text message into a room. `localId` correlates the
    /// returned event_id back to the caller's local row (for read ticks).
    func sendText(_ text: String, roomId: String, localId: String) async {
        let recipients = roomMembers[roomId] ?? []
        do {
            let eventId = try await crypto?.encryptAndSend(
                roomId: roomId,
                recipients: recipients,
                content: ["msgtype": "m.text", "body": text]
            )
            if let eventId { onSentEventId?(localId, eventId) }
        } catch {
            ErrorReporter.capture(error, context: "MatrixSession.sendText")
            AppLog.log("⚠️ Matrix sendText failed: \(error)")
        }
    }

    /// Encrypt the blob, upload the ciphertext (protocol D.3), and send an
    /// `m.image` referencing the resulting `mxc://` + decryption key.
    func sendImage(_ data: Data, mimeType: String, roomId: String, localId: String) async {
        await sendMedia(data, mimeType: mimeType, roomId: roomId, localId: localId,
                        msgtype: "m.image", filename: "image.jpg", info: ["mimetype": mimeType, "size": data.count])
    }

    /// Same as `sendImage` for a voice note (`m.audio` + duration).
    func sendAudio(_ data: Data, mimeType: String, durationMs: Int, roomId: String, localId: String) async {
        await sendMedia(data, mimeType: mimeType, roomId: roomId, localId: localId,
                        msgtype: "m.audio", filename: "voice.m4a",
                        info: ["mimetype": mimeType, "size": data.count, "duration": durationMs])
    }

    private func sendMedia(
        _ data: Data, mimeType: String, roomId: String, localId: String,
        msgtype: String, filename: String, info: [String: Any]
    ) async {
        guard let creds, let mediaBase = mediaBaseURL else {
            AppLog.log("⚠️ media send dropped — no media base / creds")
            return
        }
        do {
            let file = try await MatrixMedia.encryptAndUpload(
                data, mediaBaseURL: mediaBase, accessToken: creds.accessToken, filename: filename)
            let content: [String: Any] = ["msgtype": msgtype, "body": filename, "file": file, "info": info]
            let eventId = try await crypto?.encryptAndSend(
                roomId: roomId, recipients: roomMembers[roomId] ?? [], content: content)
            if let eventId { onSentEventId?(localId, eventId) }
        } catch {
            ErrorReporter.capture(error, context: "MatrixSession.sendMedia")
            AppLog.log("⚠️ Matrix media send failed: \(error)")
        }
    }

    /// Download + decrypt an `EncryptedFile` blob (for inbound m.image/m.audio).
    func downloadMedia(file: [String: Any]) async -> Data? {
        guard let creds, let mediaBase = mediaBaseURL,
              let parsed = MatrixMedia.EncryptedFile(file) else { return nil }
        return try? await MatrixMedia.downloadAndDecrypt(
            parsed, mediaBaseURL: mediaBase, accessToken: creds.accessToken)
    }

    /// Private read receipt for the latest event in a room (protocol D.2).
    func sendReadReceipt(roomId: String, eventId: String) async {
        let path = "/_matrix/client/v3/rooms/\(roomId)/receipt/m.read.private/\(eventId)"
        do {
            _ = try await gateway?.request(method: "POST", path: percentEncodePath(path), body: [:])
        } catch {
            ErrorReporter.capture(error, context: "MatrixSession.sendReadReceipt")
        }
    }

    // MARK: - Control-room commands (protocol E)

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

    func checkPluginUpdate() { sendControlCommand(["command": "plugin.update_check"]) }
    func applyPluginUpdate() { sendControlCommand(["command": "plugin.update", "restart": true]) }

    /// Mute / unmute a room via a homeserver push rule (protocol D.2).
    func muteRoom(_ roomId: String) {
        Task {
            let path = "/_matrix/client/v3/pushrules/global/room/\(roomId)"
            do {
                _ = try await gateway?.request(method: "PUT", path: percentEncodePath(path), body: ["actions": ["dont_notify"]])
            } catch {
                ErrorReporter.capture(error, context: "MatrixSession.muteRoom")
            }
        }
    }

    func unmuteRoom(_ roomId: String) {
        Task {
            let path = "/_matrix/client/v3/pushrules/global/room/\(roomId)"
            do {
                _ = try await gateway?.request(method: "DELETE", path: percentEncodePath(path), body: nil)
            } catch {
                ErrorReporter.capture(error, context: "MatrixSession.unmuteRoom")
            }
        }
    }

    /// Clear the last surfaced command error (UI dismiss).
    func clearCommandError() { lastCommandError = nil }

    private func sendControlCommand(_ fields: [String: Any]) {
        guard let controlRoomId, let crypto else {
            AppLog.log("⚙️ control command dropped — no control room / crypto yet")
            lastCommandError = "Can't reach your plugin yet. Make sure it's running and synced, then try again."
            return
        }
        var content: [String: Any] = ["msgtype": "chat4000.command"]
        content.merge(fields) { _, new in new }
        let recipients = roomMembers[controlRoomId] ?? []
        Task {
            do {
                _ = try await crypto.encryptAndSend(
                    roomId: controlRoomId,
                    recipients: recipients,
                    content: content,
                    cleartextEnvelope: ["chat4000.push": false]
                )
            } catch {
                ErrorReporter.capture(error, context: "MatrixSession.controlCommand")
                AppLog.log("⚙️ control command send failed: \(error)")
                lastCommandError = "Couldn't send that to your plugin. Please try again."
            }
        }
    }

    /// Decrypted control-room event → parse `chat4000.command_result` (E).
    private func handleControlEvent(clear: String?) {
        guard let clear,
              let data = clear.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [String: Any],
              content["msgtype"] as? String == "chat4000.command_result"
        else { return }
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
                applyAutoOpen()
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

    // MARK: - Push

    /// Register the APNs token as a homeserver pusher (protocol D.2). The
    /// gateway overwrites `data.url` and injects `data.user_id`.
    func registerPushToken(_ token: String) async {
        let appId = Bundle.main.bundleIdentifier ?? "com.neonnode.chat94app"
        let body: [String: Any] = [
            "pushkey": token,
            "kind": "http",
            "app_id": appId,
            "app_display_name": "chat4000",
            "device_display_name": Self.deviceDisplayName,
            "lang": "en",
            "data": [
                "url": MatrixEnvironment.current.notificationPushURL,
                "format": "event_id_only"
            ]
        ]
        do {
            _ = try await gateway?.request(method: "POST", path: "/_matrix/client/v3/pushers/set", body: body)
            AppLog.log("✅ APNs pusher registered (app_id=\(appId))")
        } catch {
            ErrorReporter.capture(error, context: "MatrixSession.pusherSet")
            AppLog.log("❌ pusher set failed: \(error)")
        }
    }

    // MARK: - Background wake (silent push drain)

    /// Drain on a silent push: ensure the gateway is connected and wait for one
    /// processed sync (bounded). Reuses this session's single OlmMachine — no
    /// second crypto store is opened. Notifications for new push-eligible plugin
    /// messages are posted from `processRoom` while backgrounded.
    func backgroundWake() async -> Bool {
        if connectionState != .connected { await connect() }
        guard connectionState == .connected else { return false }
        await waitForSync(timeout: .seconds(8))
        return true
    }

    private func waitForSync(timeout: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            syncWaiters.append(continuation)
            Task { try? await Task.sleep(for: timeout); self.resumeSyncWaiters() }
        }
    }

    private func resumeSyncWaiters() {
        let waiters = syncWaiters
        syncWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// True when the app is not foregrounded (iOS). Always false on macOS, which
    /// has no silent-push background drain.
    private var isBackgrounded: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState != .active
        #else
        false
        #endif
    }

    /// Post a local notification for a newly-decrypted, push-eligible plugin
    /// message (mirrors the `chat4000.push` flag, protocol E), deduped by event
    /// id and capped per sync batch. Streaming partials (`chat4000.push: false`)
    /// and tool/status events never notify.
    private func maybePostBackgroundNotification(outer: SyncEvent, clear: String?) {
        guard backgroundNotifyCount < 3, let eid = outer.eventId, !Self.wasNotified(eid) else { return }
        // Push eligibility: explicit `chat4000.push: false` on the cleartext
        // envelope → not the final answer → skip.
        if let envelope = parseJSON(outer.rawJSON)?["content"] as? [String: Any],
           (envelope["chat4000.push"] as? Bool) == false { return }
        guard let clear, let obj = parseJSON(clear),
              let content = obj["content"] as? [String: Any] else { return }

        let body: String
        switch content["msgtype"] as? String {
        case "m.text", "m.notice", "m.emote":
            let newContent = content["m.new_content"] as? [String: Any]
            body = (newContent?["body"] as? String) ?? (content["body"] as? String) ?? "New message"
        case "m.image": body = "📷 Photo"
        case "m.audio": body = "🎤 Voice message"
        default: return // tool / status / other → no notification
        }

        Self.markNotified(eid)
        backgroundNotifyCount += 1
        Task { await PushNotificationManager.shared.presentLocalNotification(body: body) }
    }

    // MARK: - Helpers

    /// True when we're invited (not joined) to a room — via sliding-sync
    /// `invite_state`, or our own `m.room.member` state showing `invite`.
    private func isInvited(_ room: SyncRoom) -> Bool {
        if room.isInvite { return true }
        guard let userId else { return false }
        for event in room.requiredState where event.type == "m.room.member" && event.stateKey == userId {
            if let obj = parseJSON(event.rawJSON),
               let content = obj["content"] as? [String: Any],
               content["membership"] as? String == "invite" {
                return true
            }
        }
        return false
    }

    private func joinRoom(_ roomId: String) async {
        let path = "/_matrix/client/v3/rooms/\(roomId)/join"
        do {
            _ = try await gateway?.request(method: "POST", path: percentEncodePath(path), body: [:])
        } catch {
            ErrorReporter.capture(error, context: "MatrixSession.joinRoom")
            // Let a later sync re-surface the invite so we retry.
            joinedInviteAttempts.remove(roomId)
            AppLog.log("📨 join failed for \(roomId): \(error)")
        }
    }

    private func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Per-account durably-persisted sync position (protocol D.1). The device is
    /// the source of truth for `pos`; we resend it on reconnect so un-acked
    /// to-device room keys are re-delivered rather than lost.
    private static func syncPosKey(_ userId: String?) -> String { "chat4000.syncPos.\(userId ?? "")" }
    private static func saveSyncPos(_ pos: String, userId: String?) {
        UserDefaults.standard.set(pos, forKey: syncPosKey(userId))
    }
    private static func loadSyncPos(userId: String) -> String? {
        UserDefaults.standard.string(forKey: syncPosKey(userId))
    }

    /// Bounded record of event ids we've already notified for, so a cold-launch
    /// drain (which re-sees recent timeline) doesn't re-alert old messages.
    private static let notifiedKey = "chat4000.notifiedEventIds"
    private static func wasNotified(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: notifiedKey) ?? []).contains(id)
    }
    private static func markNotified(_ id: String) {
        var ids = UserDefaults.standard.stringArray(forKey: notifiedKey) ?? []
        ids.append(id)
        if ids.count > 200 { ids.removeFirst(ids.count - 200) }
        UserDefaults.standard.set(ids, forKey: notifiedKey)
    }

    /// Percent-encode the path segments (room ids / event ids contain `!`, `:`,
    /// `@`) while leaving the slashes and any query string intact.
    private func percentEncodePath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~?=&")
        return parts.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    private static func shortId(_ id: String) -> String {
        let trimmed = id.hasPrefix("!") ? String(id.dropFirst()) : id
        return trimmed.split(separator: ":").first.map(String.init) ?? id
    }

    private static var platform: String {
        #if os(macOS)
        "macos"
        #else
        "ios"
        #endif
    }

    private static var deviceDisplayName: String {
        #if os(macOS)
        "chat4000 Mac"
        #else
        "chat4000 iPhone"
        #endif
    }
}
