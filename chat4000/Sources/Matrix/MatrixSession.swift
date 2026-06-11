import Foundation
import SwiftData
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
        // Order = real progress order (rawValue drives the progress bar), so it only
        // ever moves FORWARD: you wait for the plugin's invite first, THEN join the
        // workspace. The old order had these two swapped, so the bar jumped backward
        // (0.75 → 0.50) when the invite arrived.
        case connecting, syncing, waitingForPlugin, joiningWorkspace, ready
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
    /// True once we've been stuck in a plugin-dependent setup phase
    /// (`waitingForPlugin` / `joiningWorkspace`) past `setupStallTimeout`. The
    /// plugin must invite us and key the control room; if it crashed mid-pairing,
    /// neither ever arrives and the "Setting up" progress screen would otherwise
    /// spin forever. The UI swaps the spinner for an actionable "plugin isn't
    /// responding" state when this flips true.
    private(set) var setupStalled = false
    @ObservationIgnored private var setupStallTask: Task<Void, Never>?
    /// How long to wait in a plugin-dependent setup phase before surfacing the
    /// stall. Generous on purpose — the gateway can batch sliding-sync delivery
    /// in bursts up to ~60s, so a healthy-but-slow plugin's invite may arrive
    /// late; this window stays clear of typical batching and only catches the
    /// genuinely-no-show (crashed) case. The stall is non-destructive: we keep
    /// waiting and still auto-advance if the invite lands afterward.
    static let setupStallTimeout: Duration = .seconds(45)
    /// I2: true once the plugin is KEYED in the control room (its device is known
    /// and has an Olm session), so a control command actually reaches it instead of
    /// sharing the key to 0 devices. Gates the "connected"/ready UI and the
    /// new-session button. Recomputed each sync from the crypto store (cached read).
    private(set) var isWorkspaceReady = false

    @ObservationIgnored var onConnectionStateChange: ((ConnectionState) -> Void)?

    // MARK: - Rooms (sessions)

    struct RoomSummary: Identifiable, Equatable {
        let id: String
        var name: String
        var unreadCount: Int = 0
        var isPinned: Bool = false
        var isMuted: Bool = false
    }

    struct DevicePairingState: Equatable {
        enum Phase: String, Equatable {
            case idle
            case starting
            case codeReady
            case completed
            case expired
            case cancelled
            case failed
        }

        var phase: Phase = .idle
        var pairId: String?
        var code: String?
        var message: String?

        var canCancel: Bool {
            pairId != nil && (phase == .starting || phase == .codeReady)
        }

        static let idle = DevicePairingState()
    }

    struct DevicePairingPayload: Equatable {
        enum Kind: Equatable {
            case startResult
            case cancelResult
            case status
        }

        var kind: Kind
        var pairId: String?
        var code: String?
        var state: String?
        var error: String?
    }

    struct StoredRoomSnapshot: Codable, Equatable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int
        var roomOrder: [String]
        var roomMembers: [String: [String]]
        var roomNames: [String: String]
        var spaceRooms: [String]
        var encryptedRooms: [String]
        var roomKinds: [String: String]
        var pinnedRoomIds: [String]
        var mutedRoomIds: [String]
        var activeRoomId: String?

        init(
            roomOrder: [String],
            roomMembers: [String: [String]],
            roomNames: [String: String],
            spaceRooms: [String],
            encryptedRooms: [String],
            roomKinds: [String: String],
            pinnedRoomIds: [String],
            mutedRoomIds: [String],
            activeRoomId: String?
        ) {
            self.schemaVersion = Self.currentSchemaVersion
            self.roomOrder = roomOrder
            self.roomMembers = roomMembers
            self.roomNames = roomNames
            self.spaceRooms = spaceRooms
            self.encryptedRooms = encryptedRooms
            self.roomKinds = roomKinds
            self.pinnedRoomIds = pinnedRoomIds
            self.mutedRoomIds = mutedRoomIds
            self.activeRoomId = activeRoomId
        }
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
    private(set) var devicePairingState = DevicePairingState.idle {
        didSet { emitAddDeviceFunnelIfTerminal(from: oldValue.phase) }
    }

    /// Per-event delivery to the timeline mapper (active room only, plus replay
    /// on room switch). `live` is false for backfilled/replayed history.
    @ObservationIgnored var onRoomEvent: ((_ roomId: String, _ event: DecryptedRoomEvent, _ live: Bool) -> Void)?
    /// An outbound message's send completed → its homeserver event_id (for
    /// correlating later read receipts). `localId` is what `sendText`'s caller used.
    @ObservationIgnored var onSentEventId: ((_ localId: String, _ eventId: String) -> Void)?
    /// A peer (the plugin) read up to `eventId` → drives the "read" tick.
    @ObservationIgnored var onReadReceipt: ((_ eventId: String) -> Void)?
    @ObservationIgnored var onRoomDeleted: ((_ roomId: String) -> Void)?

    // MARK: - Internals

    @ObservationIgnored private var gateway: GatewayClient?
    @ObservationIgnored private var crypto: CryptoEngine?
    @ObservationIgnored private var creds: MatrixCredentialStore.Stored?
    /// HTTP base for authenticated media (protocol D.3), derived from the
    /// gateway URL on connect.
    @ObservationIgnored private var mediaBaseURL: String?
    @ObservationIgnored private var modelContext: ModelContext?

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
    @ObservationIgnored private var roomKinds: [String: String] = [:]
    @ObservationIgnored private var roomUnreadCounts: [String: Int] = [:]
    @ObservationIgnored private var pinnedRoomIds: [String] = []
    @ObservationIgnored private var mutedRoomIds: Set<String> = []
    @ObservationIgnored private var pendingDeleteRoomIds: [String] = []

    @ObservationIgnored private var pendingAutoOpen = false
    /// CL7 source hint: true while a user-initiated `session.new` is outstanding, so
    /// the next room that appears is attributed to "user" vs "plugin".
    @ObservationIgnored private var pendingUserSessionCreate = false
    @ObservationIgnored private var autoOpenRoomId: String?
    @ObservationIgnored private var reconnectAttempts = 0
    /// Protocol D.1 two-cursor sliding sync: the last to-device cursor we have
    /// DURABLY persisted (alongside its keys). Carried forward and re-sent in
    /// every `sync_ack`, and re-sent in `sync_start` on reconnect. nil until the
    /// first to-device batch is durably persisted.
    @ObservationIgnored private var lastToDevicePos: String?
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

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// True if paired credentials are persisted (drives launch routing).
    var isPaired: Bool { MatrixCredentialStore.load() != nil }

    // MARK: - Pairing / connect

    func pair(code: String) async {
        // A pairing is a fresh start — clear any previous session's rooms, active
        // chat, and cached events so we never surface an old session the user is
        // no longer connected to.
        resetSessionState()
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
            // CL1 pairing_completed (declared-but-never-emitted regression fix) +
            // CL6 account_linked (event + $set + register super prop), once per pair.
            TelemetryManager.shared.track(.pairingCompleted, properties: ["flow": "matrix_join"])
            TelemetryManager.shared.linkAccount(userId: redeemed.userId)
        } catch .cancelled {
            // Benign — a torn-down pairing flow. Don't surface as a failure.
            AppLog.log("⚙️ Matrix pairing cancelled")
        } catch {
            // Expected, user-facing pairing failures (bad/expired code, etc.) and
            // any classified boundary failure. Reporting (if warranted) already
            // happened at the boundary that produced the AppError.
            applyGatewayVersionGateIfNeeded(error)
            connectionState = .failed(error.message)
            TelemetryManager.shared.track(.pairingFailed,  // CL2
                                          properties: ["flow": "matrix_join", "reason": error.message])
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
            applyGatewayVersionGateIfNeeded(error)
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
        if let uid {
            UserDefaults.standard.removeObject(forKey: Self.syncPosKey(uid))
            UserDefaults.standard.removeObject(forKey: Self.toDevicePosKey(uid))
            removeRoomSnapshot(userId: uid)
        }
        lastToDevicePos = nil
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
        if let userId {
            removeRoomSnapshot(userId: userId)
        }
        roomOrder = []
        roomMembers = [:]
        roomNames = [:]
        spaceRooms = []
        encryptedRooms = []
        joinedInviteAttempts = []
        trackedUsers = []
        seenEventIds = []
        roomKinds = [:]
        pinnedRoomIds = []
        mutedRoomIds = []
        pendingDeleteRoomIds = []
        devicePairingState = .idle
        rooms = []
        activeRoomId = nil
        controlRoomId = nil
        autoOpenRoomId = nil
        pendingAutoOpen = false
        requestedKeyFor = []
        undecrypted = [:]
        setupPhase = .connecting
        setupStallTask?.cancel()
        setupStallTask = nil
        setupStalled = false
    }

    private func applyGatewayVersionGateIfNeeded(_ error: AppError) {
        guard case let .unsupportedClientVersion(minClientVersion, maxClientVersion) = error else {
            return
        }
        VersionPolicyManager.shared.requireUpgradeFromGateway(
            minClientVersion: minClientVersion,
            maxClientVersion: maxClientVersion
        )
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
        // Connected as a DIFFERENT account than the one currently in memory → the
        // previous session's rooms/active chat/cached events are stale. Clear them
        // so a reconnect to a new session doesn't surface the old chat. (A plain
        // reconnect to the SAME user keeps its state and resumes.)
        if let previous = userId, previous != auth.userId {
            AppLog.log("🔄 identity changed %@ → %@; clearing stale session state", previous, auth.userId)
            resetSessionState()
        }
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

        let restoredRoomSnapshot = restoreRoomSnapshotIfNeeded(userId: auth.userId)
        restoreCryptoStateForRoomSnapshot()

        // Publish our device keys / one-time keys before syncing.
        try await crypto.runOutgoingRequests()
        // Resume from saved `pos` whenever we have a room snapshot in memory. On a
        // process restart the snapshot is restored from SwiftData before this point,
        // so normal app opens do not force a full timeline replay. If no snapshot
        // exists (fresh pairing, old build, or corrupt cache), omit `pos` once to
        // recover the room list from the gateway.
        let savedRoomPos = Self.loadSyncPos(userId: auth.userId)
        let resumePos = Self.roomCursorForStart(
            savedPos: savedRoomPos,
            restoredRoomCount: roomOrder.count
        )
        let syncStartMode = resumePos == nil ? "cold-full" : "cursor-resume"
        if resumePos == nil {
            AppLog.log(
                "🚨 FULL SYNC START pos=nil rooms_in_memory=%d restored_snapshot=%@ saved_pos=%@ - " +
                    "if you're seeing this and we didn't just pair or create the first SwiftData room snapshot, " +
                    "there's probably some kind of bug here; app is not supposed to full sync in the middle",
                roomOrder.count,
                String(restoredRoomSnapshot),
                savedRoomPos ?? "nil"
            )
            TelemetryManager.shared.track(.fullSyncTriggered, properties: [  // CL15
                "rooms_in_memory": roomOrder.count,
                "restored_snapshot": restoredRoomSnapshot,
                "had_saved_pos": savedRoomPos != nil
            ])
        }
        // The TO-DEVICE cursor is independent of the room snapshot (two cursors,
        // D.1). Its keys live in the crypto store (which survives a cold launch),
        // so ALWAYS resume it from durable storage — even on a cold-full sync that
        // re-fetches the whole room list with pos=nil — so un-acked Megolm keys are
        // re-delivered rather than deleted. Omitted only when none was ever
        // persisted (a genuinely fresh sync).
        let resumeToDevicePos = Self.loadToDevicePos(userId: auth.userId)
        lastToDevicePos = resumeToDevicePos
        AppLog.log("🔗 startSync %@ (rooms_in_memory=%d restored_snapshot=%@) pos=%@ to_device_pos=%@",
                   syncStartMode, roomOrder.count,
                   String(restoredRoomSnapshot),
                   resumePos ?? "nil", resumeToDevicePos ?? "nil")
        gateway.startSync(body: SlidingSync.requestBody(), pos: resumePos, toDevicePos: resumeToDevicePos)

        if let token = PushNotificationManager.shared.deviceToken {
            await registerPushToken(token)
        }
    }

    /// The socket dropped. Start a reconnect cycle — but ONLY if we were connected
    /// (ignore spurious closes while disconnected/already reconnecting, so we never
    /// spin up two parallel loops).
    private func handleSocketClosed() async {
        guard connectionState == .connected else { return }
        connectionState = .reconnecting
        await reconnectLoop()
    }

    /// Back off and retry until we reconnect (startClient flips state to
    /// `.connected` and zeroes `reconnectAttempts`) or the state leaves
    /// `.reconnecting` (e.g. the user signs out). This is the RETRY step and must
    /// NOT be gated on `== .connected` — that guard belongs to `handleSocketClosed`
    /// only; gating the retry there is what previously stopped reconnection dead
    /// after a single failed attempt, stranding the app on "Connecting".
    private func reconnectLoop() async {
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
            AppLog.log("❌ reconnect failed: \(error) — retrying")
            await reconnectLoop()
        }
    }

    // MARK: - Sync handling

    private func handleSync(_ frame: [String: Any]) async {
        backgroundNotifyCount = 0
        let sync = SyncModel.parse(frame)
        if let pinned = sync.pinnedRoomIds {
            pinnedRoomIds = pinned
        }
        if let muted = sync.mutedRoomIds {
            mutedRoomIds = Set(muted)
        }
        AppLog.log("🔄 sync pos=%@ rooms=%d to_device=%d", sync.pos ?? "nil", sync.rooms.count, sync.toDevice.count)
        for r in sync.rooms {
            AppLog.log("🏠 room %@ kind=%@ space=%@ invite=%@ enc=%@ members=%d tl=%d",
                       r.id, r.roomKind ?? "nil", String(r.isSpace), String(r.isInvite),
                       String(r.isEncrypted), r.members.count, r.timeline.count)
        }
        // Feed e2ee state (to-device room keys, device lists, OTK counts) and
        // drain outgoing crypto requests BEFORE decrypting room events.
        // `cryptoPersisted` gates the to-device cursor (D.1, "Sync cursor & key
        // delivery"): we may advance `to_device_pos` ONLY when this frame's keys
        // are confirmed durably on disk. `processSync` returning without throwing
        // is that confirmation (the crypto store committed the batch before
        // returning). A throw means we CANNOT confirm the keys are saved, so we
        // conservatively hold the cursor and let the homeserver re-deliver this
        // frame's to-device next sync (idempotent re-import) — never ack it lost.
        var cryptoPersisted = true
        do { try await crypto?.processSync(sync) } catch {
            cryptoPersisted = false
            ErrorReporter.capture(error, context: "MatrixSession.processSync")
            AppLog.log("⚙️ crypto.processSync failed: \(error)")
        }

        for room in sync.rooms { await processRoom(room) }

        // Peer receipts drive the outgoing "read" tick. Our own private receipts
        // are the cross-device read marker for this Matrix user, so they clear the
        // per-room unread count without clearing local notifications on this device.
        for receipt in sync.receipts {
            if receipt.userId == userId {
                markRoomReadLocally(roomId: receipt.roomId, rebuild: false)
                AppLog.debug("👁️ own read receipt in %@ up to %@ → unread=0", receipt.roomId, receipt.eventId)
            } else {
                AppLog.debug("👁️ read receipt from %@ up to %@", receipt.userId, receipt.eventId)
                onReadReceipt?(receipt.eventId)
            }
        }
        retryUndecrypted()
        rebuildRoomList()
        applyAutoOpen()
        updateSetupPhase()

        // Durable-ack BOTH cursors (protocol D.1, "Sync cursor & key delivery"):
        // processSync persisted the to-device Megolm keys + crypto state and the
        // dispatch above persisted messages, so it's now safe to let the gateway
        // advance upstream (and the homeserver delete the acked to-device). The
        // gateway holds the cursors until this arrives — without it, sync never
        // advances and no new messages are delivered.
        if let pos = sync.pos {
            // Resolve the to-device cursor to persist + ack: advance to this
            // frame's `to_device_pos` ONLY if its keys were durably persisted;
            // otherwise carry the last good value forward (a frame with no
            // to-device section, or one whose crypto persist failed, must not
            // advance the cursor past unsaved keys). Persist to durable storage
            // AFTER the crypto-store write above, then ack — never before, so a
            // crash can only ever lose the cursor (→ harmless re-delivery), never
            // ack keys that aren't saved.
            let nextToDevicePos = Self.resolveToDevicePos(
                cryptoPersisted: cryptoPersisted, frame: sync.toDevicePos, last: lastToDevicePos)
            if let nextToDevicePos, nextToDevicePos != lastToDevicePos {
                Self.saveToDevicePos(nextToDevicePos, userId: userId)
            }
            lastToDevicePos = nextToDevicePos
            Self.saveSyncPos(pos, userId: userId)
            gateway?.syncAck(pos: pos, toDevicePos: lastToDevicePos)
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
        setUnreadCount(roomId: room.id, count: isActive ? 0 : room.notificationCount, rebuild: false)
        AppLog.debug("🏠· process %@ control=%@ active=%@ timeline=%d",
                     room.id, String(isControl), String(isActive), room.timeline.count)

        // Event-id dedup. We are GENERALLY AGAINST client-side dedup — it can hide a
        // real upstream duplication bug (plugin/gateway sending something twice). The
        // plugin sends each event once and the gateway never re-files an event, so in
        // steady state this never fires. We keep it ONLY for one unavoidable case:
        //
        //   RECONNECT RE-SEND. We render a batch's events BEFORE we save its bookmark
        //   (pos) — on purpose, so we can never LOSE a message. Example: the gateway
        //   sends [msg96, msg97, msg98] at pos=98; we render all three; the socket
        //   drops BEFORE we persist+ack pos 98, so our saved bookmark is still 95. On
        //   reconnect we resume from 95, the gateway re-sends 96–98 (which are already
        //   on screen), and without this guard they'd render a SECOND time. Saving the
        //   bookmark first would instead LOSE messages on a crash — so we render-first,
        //   advance-the-bookmark-last (same "re-send beats lose" rule as the Megolm
        //   keys), and dedup absorbs the re-send. This is the ONLY reason it exists.
        for outer in room.timeline {
            // Dedup ALL timeline events by event_id — INCLUDING chat4000.status
            // (protocol E). The gateway re-delivers the recent window on state-change
            // syncs, so without this we'd re-process stale status and re-arm the
            // label's TTL. The label is driven by the LATEST status by ts (below), so
            // we never need to re-process an old one.
            guard let eid = outer.eventId, seenEventIds.insert(eid).inserted else { continue }

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
            // Deliver to the room's view model regardless of which room is front
            // (NO active gate): every room cooks + persists its own rows live, so a
            // background room's always-mounted view is already correct when brought
            // to front — and the active-room race that bled one room's tool chips
            // into another room's timeline is gone structurally.
            onRoomEvent?(room.id, event, true)
            if isBackgrounded, !event.isOwn {
                maybePostBackgroundNotification(roomId: room.id, outer: outer, clear: clear)
            }
        }

        // chat4000.status is NO LONGER read here. It is delivered as an E2EE
        // TIMELINE event (protocol E "Agent status"), not via required_state, so it
        // rides the normal decrypt → onRoomEvent → RoomViewModel.ingest
        // path and drives the label there. The old required_state read was lossy
        // (the timeline is the source of truth) and is removed.
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
            // No active gate — deliver to the room's view model whichever room is front.
            onRoomEvent?(entry.roomId, event, false)
        }
    }

    private func rebuildRoomList() {
        if controlRoomId == nil {
            controlRoomId = roomOrder.first { roomKinds[$0] == "control" }
        }
        // I2: the workspace is "ready" only when the plugin is keyed in the control
        // room — until then a control command would share the key to 0 devices.
        isWorkspaceReady = controlRoomId.map { isRoomReady($0) } ?? false
        // Sidebar = every joined room except the plugin's space and the control
        // room (protocol E). A room with no `chat4000.room_kind` is a session — but
        // we surface it ONLY once it's keyed (I2), so the user never opens a room
        // they'd message before the room key reaches the plugin.
        let pinned = Set(pinnedRoomIds)
        let muted = mutedRoomIds
        let nextRooms: [RoomSummary] = roomOrder.compactMap { id -> RoomSummary? in
            if spaceRooms.contains(id) { return nil }
            if roomKinds[id] == "control" { return nil }
            guard isRoomReady(id) else { return nil }
            return RoomSummary(
                id: id,
                name: roomNames[id] ?? Self.shortId(id),
                unreadCount: roomUnreadCounts[id] ?? 0,
                isPinned: pinned.contains(id),
                isMuted: muted.contains(id)
            )
        }
        rooms = Self.sortedRooms(nextRooms, pinnedRoomIds: pinnedRoomIds)
        AppLog.log("📋 rebuilt: ordered=%d sessions=%d spaces=%d control=%@ wsReady=%@",
                   roomOrder.count, rooms.count, spaceRooms.count, controlRoomId ?? "nil", String(isWorkspaceReady))
        saveRoomSnapshot()
    }

    /// I2: is `roomId` reachable for sending — the plugin's device list known, so a
    /// send will claim + establish + share to it (rather than to 0 devices)? A
    /// read-only crypto-store check (no network); gates UI readiness/visibility.
    private func isRoomReady(_ roomId: String) -> Bool {
        guard let crypto, let userId else { return false }
        return crypto.isRoomReachable(recipients: roomMembers[roomId] ?? [], selfUserId: userId)
    }

    /// Recompute the first-run progress phase from current room state.
    /// G4: true once the workspace has ever been set up (a control/session room
    /// existed). On relaunch we use this to SKIP the first-run setup/"connecting"
    /// screen and go straight to the chat, instead of flashing it every cold start.
    var hasCompletedFirstSetup: Bool { UserDefaults.standard.bool(forKey: Self.firstSetupKey) }
    private static let firstSetupKey = "chat4000.didCompleteFirstSetup"

    private func updateSetupPhase() {
        let previous = setupPhase
        // I2: "ready" requires the plugin to be KEYED (control room keyed, or a
        // keyed session already visible) — not merely that a control room exists.
        // Until then we hold on "Joining your workspace…" so the user can't fire a
        // command before the key reaches the plugin.
        if isWorkspaceReady || !rooms.isEmpty {
            setupPhase = .ready
            UserDefaults.standard.set(true, forKey: Self.firstSetupKey)   // G4
        } else if controlRoomId != nil || !joinedInviteAttempts.isEmpty {
            setupPhase = .joiningWorkspace          // joined/known, but the plugin isn't keyed yet
        } else {
            setupPhase = .waitingForPlugin          // connected + synced, but no invite yet
        }
        updateSetupStallTimer(previous: previous, current: setupPhase)
    }

    /// Arm a one-shot timer while we're waiting on the plugin so an indefinite
    /// "Waiting for your plugin" / "Joining your workspace" spinner becomes an
    /// actionable timeout if the plugin never shows (e.g. it crashed). Reaching
    /// `.ready` (or otherwise leaving the waiting region) cancels it.
    private func updateSetupStallTimer(previous: SetupPhase, current: SetupPhase) {
        let waitingOnPlugin = current == .waitingForPlugin || current == .joiningWorkspace
        guard waitingOnPlugin else {
            // Done (or no longer waiting) — drop the timer and clear any stall.
            setupStallTask?.cancel()
            setupStallTask = nil
            if setupStalled { setupStalled = false }
            return
        }
        // Only (re)arm on an actual phase change: entering the waiting region, or
        // making forward progress within it (waitingForPlugin → joiningWorkspace
        // means the plugin IS alive, so reset the clock). A plain re-sync that
        // leaves the phase unchanged must NOT restart the clock, or a steady
        // stream of syncs would push the deadline out forever and it'd never fire.
        guard previous != current else { return }
        setupStalled = false
        armSetupStallTimer()
    }

    private func armSetupStallTimer() {
        setupStallTask?.cancel()
        setupStallTask = Task { [weak self] in
            try? await Task.sleep(for: Self.setupStallTimeout)
            guard !Task.isCancelled, let self else { return }
            // Still waiting on the plugin after the timeout → surface it.
            guard self.setupPhase == .waitingForPlugin || self.setupPhase == .joiningWorkspace else { return }
            self.setupStalled = true
            AppLog.log("⏱️ setup stalled — plugin no-show after %ds (phase=%@)",
                       Int(Self.setupStallTimeout.components.seconds), self.setupPhase.label)
        }
    }

    /// User asked to keep waiting after a stall — clear the flag and restart the
    /// clock. This does not itself contact the plugin (recovery is the plugin
    /// coming back); the next sync advances the phase if it has.
    func retrySetupWait() {
        guard setupPhase == .waitingForPlugin || setupPhase == .joiningWorkspace else { return }
        setupStalled = false
        armSetupStallTimer()
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
        PushNotificationManager.shared.clearSessionNotifications(roomId: id)
        markRoomReadLocally(roomId: id, rebuild: true)
        guard activeRoomId != id else {
            onActiveRoomChange?(id)
            return
        }
        activeRoomId = id
        // Just record which room is front — no replay. Each room's view model is
        // always mounted and was fed its events live, so there is nothing to
        // re-cook or re-deliver on switch.
        onActiveRoomChange?(id)
    }

    func clearNotificationsForActiveRoom() {
        guard let activeRoomId else { return }
        PushNotificationManager.shared.clearSessionNotifications(roomId: activeRoomId)
        markRoomReadLocally(roomId: activeRoomId, rebuild: true)
    }

    private func markRoomReadLocally(roomId: String, rebuild: Bool) {
        setUnreadCount(roomId: roomId, count: 0, rebuild: rebuild)
    }

    private func setUnreadCount(roomId: String, count: Int, rebuild: Bool) {
        let sanitizedCount = max(0, count)
        guard roomUnreadCounts[roomId] != sanitizedCount else { return }
        roomUnreadCounts[roomId] = sanitizedCount
        if rebuild { rebuildRoomList() }
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
        // I2 (app-layer guard, send path unchanged): never fire the command before
        // the plugin is keyed — otherwise it's encrypted to 0 recipients and lost,
        // which is exactly the "tap 3 times" bug. The button is hidden until ready
        // too, but this is the backstop.
        guard isWorkspaceReady else {
            AppLog.log("🆕 requestNewSession ignored — workspace not keyed yet")
            lastCommandError = "Still setting up the secure channel — one moment."
            return
        }
        var fields: [String: Any] = ["command": "session.new", "agent_id": "main"]
        if let title, !title.isEmpty { fields["title"] = String(title.prefix(255)) }
        sendControlCommand(fields)
        pendingAutoOpen = true
        pendingUserSessionCreate = true  // CL7: the resulting new room is user-sourced
    }

    /// CL7: consume the source attribution for one newly-appeared room. Returns
    /// "user" once after a local `requestNewSession`, "plugin" otherwise.
    func consumeSessionCreateSource() -> String {
        defer { pendingUserSessionCreate = false }
        return pendingUserSessionCreate ? "user" : "plugin"
    }

    func renameSession(roomId: String, title: String) {
        sendControlCommand(["command": "session.rename", "room_id": roomId, "title": String(title.prefix(255))])
        TelemetryManager.shared.track(.sessionRenamed, properties: ["session_count": rooms.count])  // CL9
    }

    func deleteSession(roomId: String) {
        pendingDeleteRoomIds.append(roomId)
        sendControlCommand(["command": "session.delete", "room_id": roomId])
        TelemetryManager.shared.track(.sessionDeleted, properties: ["session_count": rooms.count])  // CL10
    }

    func pinSession(roomId: String) {
        setPinned(roomId: roomId, pinned: true)
    }

    func unpinSession(roomId: String) {
        setPinned(roomId: roomId, pinned: false)
    }

    func checkPluginUpdate() { sendControlCommand(["command": "plugin.update_check"]) }
    func applyPluginUpdate() { sendControlCommand(["command": "plugin.update", "restart": true]) }

    func startDevicePairing() {
        guard isWorkspaceReady, controlRoomId != nil, crypto != nil else {
            AppLog.log("🔗 device.pair_start ignored — workspace not keyed yet")
            devicePairingState = DevicePairingState(
                phase: .failed,
                pairId: nil,
                code: nil,
                message: "Still setting up the secure channel — one moment."
            )
            return
        }
        TelemetryManager.shared.track(.addDeviceFlowStarted)  // CL21
        devicePairingState = DevicePairingState(phase: .starting)
        sendControlCommand(["command": "device.pair_start"])
    }

    /// CL21 add-device funnel close: emit once per terminal transition. `completed`
    /// → success; `failed`/`expired`/`cancelled` → `_failed {reason}` (every
    /// non-completion closes the funnel so started/completed/failed reconcile).
    private func emitAddDeviceFunnelIfTerminal(from oldPhase: DevicePairingState.Phase) {
        let new = devicePairingState.phase
        guard new != oldPhase else { return }
        switch new {
        case .completed:
            TelemetryManager.shared.track(.addDeviceFlowCompleted)
        case .failed, .expired, .cancelled:
            let reason: String
            switch new {
            case .expired: reason = "expired"
            case .cancelled: reason = "cancelled"
            default: reason = devicePairingState.message ?? "failed"
            }
            TelemetryManager.shared.track(.addDeviceFlowFailed, properties: ["reason": reason])
        default:
            break
        }
    }

    func cancelDevicePairing() {
        guard let pairId = devicePairingState.pairId, !pairId.isEmpty else {
            devicePairingState = .idle
            return
        }
        sendControlCommand(["command": "device.pair_cancel", "pair_id": pairId])
    }

    func clearDevicePairing() {
        devicePairingState = .idle
    }

    /// Mute / unmute a room via a homeserver push rule (protocol D.2).
    func muteRoom(_ roomId: String) {
        setMuted(roomId: roomId, muted: true)
        Task {
            let path = "/_matrix/client/v3/pushrules/global/room/\(roomId)"
            do {
                _ = try await gateway?.request(method: "PUT", path: percentEncodePath(path), body: ["actions": ["dont_notify"]])
            } catch {
                await MainActor.run { self.setMuted(roomId: roomId, muted: false) }
                ErrorReporter.capture(error, context: "MatrixSession.muteRoom")
            }
        }
    }

    func unmuteRoom(_ roomId: String) {
        setMuted(roomId: roomId, muted: false)
        Task {
            let path = "/_matrix/client/v3/pushrules/global/room/\(roomId)"
            do {
                _ = try await gateway?.request(method: "DELETE", path: percentEncodePath(path), body: nil)
            } catch {
                await MainActor.run { self.setMuted(roomId: roomId, muted: true) }
                ErrorReporter.capture(error, context: "MatrixSession.unmuteRoom")
            }
        }
    }

    /// Clear the last surfaced command error (UI dismiss).
    func clearCommandError() { lastCommandError = nil }

    private func sendControlCommand(_ fields: [String: Any]) {
        let command = fields["command"] as? String
        guard let controlRoomId, let crypto else {
            AppLog.log("⚙️ control command dropped — no control room / crypto yet")
            lastCommandError = "Can't reach your plugin yet. Make sure it's running and synced, then try again."
            handleControlCommandSendFailure(command: command)
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
                handleControlCommandSendFailure(command: command)
            }
        }
    }

    private func handleControlCommandSendFailure(command: String?) {
        switch command {
        case "device.pair_start":
            devicePairingState = DevicePairingState(
                phase: .failed,
                pairId: nil,
                code: nil,
                message: "Couldn't ask your plugin for a pairing code. Please try again."
            )
        case "device.pair_cancel":
            devicePairingState = DevicePairingState(
                phase: .failed,
                pairId: devicePairingState.pairId,
                code: devicePairingState.code,
                message: "Couldn't cancel pairing. Please try again."
            )
        default:
            break
        }
    }

    /// Decrypted control-room event → parse command results and control signals (E).
    private func handleControlEvent(clear: String?) {
        guard let clear,
              let data = clear.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [String: Any]
        else { return }

        if let payload = Self.parseDevicePairingPayload(content) {
            applyDevicePairingPayload(payload)
            return
        }

        guard content["msgtype"] as? String == "chat4000.command_result" else { return }
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
        case "session.rename":
            if !ok { lastCommandError = error ?? "\(command) failed." }
        case "session.delete":
            let roomId = resolvePendingDeleteRoomId(from: c)
            if ok, let roomId {
                Task { await leaveAndForgetDeletedRoom(roomId) }
            } else {
                if let roomId { removePendingDelete(roomId) }
                lastCommandError = error ?? "session.delete failed."
            }
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

    nonisolated static func parseDevicePairingPayload(_ content: [String: Any]) -> DevicePairingPayload? {
        let msgtype = content["msgtype"] as? String
        if msgtype == "chat4000.pair_status" {
            return DevicePairingPayload(
                kind: .status,
                pairId: clippedString(content["pair_id"], maxLength: 64),
                code: nil,
                state: clippedString(content["state"], maxLength: 32),
                error: clippedString(content["error"], maxLength: 255)
            )
        }
        guard msgtype == "chat4000.command_result",
              let command = content["command"] as? String,
              command == "device.pair_start" || command == "device.pair_cancel" else {
            return nil
        }
        let rawCode = content["code"] as? String
        let normalizedCode: String?
        if let rawCode,
           rawCode.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil {
            normalizedCode = rawCode
        } else {
            normalizedCode = nil
        }
        return DevicePairingPayload(
            kind: command == "device.pair_start" ? .startResult : .cancelResult,
            pairId: clippedString(content["pair_id"], maxLength: 64),
            code: normalizedCode,
            state: nil,
            error: clippedString(content["error"], maxLength: 255)
        )
    }

    private nonisolated static func clippedString(_ value: Any?, maxLength: Int) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return String(string.prefix(maxLength))
    }

    private func applyDevicePairingPayload(_ payload: DevicePairingPayload) {
        switch payload.kind {
        case .startResult:
            if let error = payload.error {
                devicePairingState = DevicePairingState(
                    phase: .failed,
                    pairId: payload.pairId,
                    code: nil,
                    message: error
                )
            } else if let code = payload.code, let pairId = payload.pairId {
                devicePairingState = DevicePairingState(
                    phase: .codeReady,
                    pairId: pairId,
                    code: code,
                    message: nil
                )
            } else {
                devicePairingState = DevicePairingState(
                    phase: .failed,
                    pairId: payload.pairId,
                    code: nil,
                    message: "Pairing response was missing a code."
                )
            }
        case .cancelResult:
            if let error = payload.error {
                devicePairingState = DevicePairingState(
                    phase: .failed,
                    pairId: payload.pairId ?? devicePairingState.pairId,
                    code: devicePairingState.code,
                    message: error
                )
            } else {
                devicePairingState = DevicePairingState(
                    phase: .cancelled,
                    pairId: payload.pairId ?? devicePairingState.pairId,
                    code: nil,
                    message: "Pairing cancelled."
                )
            }
        case .status:
            applyDevicePairingStatus(payload)
        }
    }

    private func applyDevicePairingStatus(_ payload: DevicePairingPayload) {
        let pairId = payload.pairId ?? devicePairingState.pairId
        switch payload.state {
        case "completed":
            devicePairingState = DevicePairingState(
                phase: .completed,
                pairId: pairId,
                code: nil,
                message: "Device paired."
            )
        case "expired":
            devicePairingState = DevicePairingState(
                phase: .expired,
                pairId: pairId,
                code: nil,
                message: "Pairing code expired."
            )
        case "cancelled":
            devicePairingState = DevicePairingState(
                phase: .cancelled,
                pairId: pairId,
                code: nil,
                message: "Pairing cancelled."
            )
        case "error":
            devicePairingState = DevicePairingState(
                phase: .failed,
                pairId: pairId,
                code: nil,
                message: payload.error ?? "Pairing failed."
            )
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

    private func setPinned(roomId: String, pinned: Bool) {
        var next = pinnedRoomIds.filter { $0 != roomId }
        if pinned { next.insert(roomId, at: 0) }
        pinnedRoomIds = Self.sanitizedPinnedRoomIds(next)
        rebuildRoomList()
        TelemetryManager.shared.track(pinned ? .sessionPinned : .sessionUnpinned,  // CL11
                                      properties: ["session_count": rooms.count])
        let ids = pinnedRoomIds
        Task { [weak self] in
            await self?.persistPinnedRoomIds(ids)
        }
    }

    private func setMuted(roomId: String, muted: Bool) {
        if muted {
            mutedRoomIds.insert(roomId)
        } else {
            mutedRoomIds.remove(roomId)
        }
        rebuildRoomList()
        TelemetryManager.shared.track(muted ? .sessionMuted : .sessionUnmuted,  // CL12
                                      properties: ["session_count": rooms.count])
    }

    private func persistPinnedRoomIds(_ ids: [String]) async {
        guard let userId else { return }
        let path = "/_matrix/client/v3/user/\(userId)/account_data/chat4000.session.prefs"
        do {
            _ = try await gateway?.request(
                method: "PUT",
                path: percentEncodePath(path),
                body: ["pinned": ids]
            )
        } catch {
            ErrorReporter.capture(error, context: "MatrixSession.persistPinnedRoomIds")
            AppLog.log("⚠️ pin prefs persist failed: \(error)")
        }
    }

    private func resolvePendingDeleteRoomId(from content: [String: Any]) -> String? {
        if let roomId = content["room_id"] as? String {
            removePendingDelete(roomId)
            return roomId
        }
        guard !pendingDeleteRoomIds.isEmpty else { return nil }
        return pendingDeleteRoomIds.removeFirst()
    }

    private func removePendingDelete(_ roomId: String) {
        pendingDeleteRoomIds.removeAll { $0 == roomId }
    }

    private func leaveAndForgetDeletedRoom(_ roomId: String) async {
        removeLocalRoom(roomId)
        await sendRoomLifecycleRequest(method: "POST", roomId: roomId, action: "leave")
        await sendRoomLifecycleRequest(method: "POST", roomId: roomId, action: "forget")
    }

    private func sendRoomLifecycleRequest(method: String, roomId: String, action: String) async {
        let path = "/_matrix/client/v3/rooms/\(roomId)/\(action)"
        do {
            _ = try await gateway?.request(method: method, path: percentEncodePath(path), body: [:])
        } catch {
            ErrorReporter.capture(error, context: "MatrixSession.\(action)Room")
            AppLog.log("⚠️ room %@ failed for %@: %@", action, roomId, String(describing: error))
        }
    }

    private func removeLocalRoom(_ roomId: String) {
        roomOrder.removeAll { $0 == roomId }
        roomMembers[roomId] = nil
        roomNames[roomId] = nil
        roomKinds[roomId] = nil
        roomUnreadCounts[roomId] = nil
        spaceRooms.remove(roomId)
        encryptedRooms.remove(roomId)
        pinnedRoomIds.removeAll { $0 == roomId }
        mutedRoomIds.remove(roomId)
        onRoomDeleted?(roomId)
        rebuildRoomList()
        if activeRoomId == roomId {
            activeRoomId = rooms.first?.id
            onActiveRoomChange?(activeRoomId)
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
    private func maybePostBackgroundNotification(roomId: String, outer: SyncEvent, clear: String?) {
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
        Task {
            await PushNotificationManager.shared.presentLocalNotification(
                body: body,
                roomId: roomId,
                eventId: eid
            )
        }
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

    /// Per-account durably-persisted TO-DEVICE cursor (protocol D.1). A SEPARATE
    /// key from `pos` — the two cursors are independent. The device is the source
    /// of truth: we resend it on reconnect so un-acked Olm-wrapped Megolm keys are
    /// re-delivered rather than deleted before they were saved.
    private static func toDevicePosKey(_ userId: String?) -> String { "chat4000.toDevicePos.\(userId ?? "")" }
    private static func saveToDevicePos(_ pos: String, userId: String?) {
        UserDefaults.standard.set(pos, forKey: toDevicePosKey(userId))
    }
    private static func loadToDevicePos(userId: String) -> String? {
        UserDefaults.standard.string(forKey: toDevicePosKey(userId))
    }

    private static func legacyRoomSnapshotKey(_ userId: String?) -> String { "chat4000.roomSnapshot.\(userId ?? "")" }

    nonisolated static func roomCursorForStart(savedPos: String?, restoredRoomCount: Int) -> String? {
        restoredRoomCount > 0 ? savedPos : nil
    }

    nonisolated static func encodeRoomSnapshot(_ snapshot: StoredRoomSnapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    nonisolated static func decodeRoomSnapshot(_ data: Data) -> StoredRoomSnapshot? {
        guard let snapshot = try? JSONDecoder().decode(StoredRoomSnapshot.self, from: data),
              snapshot.schemaVersion == StoredRoomSnapshot.currentSchemaVersion else {
            return nil
        }
        return snapshot
    }

    private static func roomSnapshotDescriptor(userId: String) -> FetchDescriptor<MatrixRoomSnapshot> {
        var descriptor = FetchDescriptor<MatrixRoomSnapshot>(
            predicate: #Predicate { $0.userId == userId },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 2
        return descriptor
    }

    private func saveRoomSnapshot(_ snapshot: StoredRoomSnapshot, userId: String) {
        guard let data = Self.encodeRoomSnapshot(snapshot) else {
            AppLog.log("⚠️ room snapshot encode failed for %@", userId)
            return
        }
        guard let modelContext else {
            AppLog.log("⚠️ room snapshot not saved - no SwiftData context for %@", userId)
            return
        }
        do {
            let existing = try modelContext.fetch(Self.roomSnapshotDescriptor(userId: userId))
            if let record = existing.first {
                record.schemaVersion = snapshot.schemaVersion
                record.snapshotData = data
                record.updatedAt = .now
                for duplicate in existing.dropFirst() {
                    modelContext.delete(duplicate)
                }
            } else {
                modelContext.insert(
                    MatrixRoomSnapshot(
                        userId: userId,
                        schemaVersion: snapshot.schemaVersion,
                        snapshotData: data
                    )
                )
            }
            try modelContext.save()
        } catch {
            ErrorReporter.capture(error, context: "MatrixSession.saveRoomSnapshot")
            AppLog.log("⚠️ room snapshot save failed for %@: %@", userId, String(describing: error))
        }
    }

    private func loadRoomSnapshot(userId: String) -> StoredRoomSnapshot? {
        guard let modelContext else {
            AppLog.log("⚠️ room snapshot not loaded - no SwiftData context for %@", userId)
            return nil
        }
        do {
            let records = try modelContext.fetch(Self.roomSnapshotDescriptor(userId: userId))
            for duplicate in records.dropFirst() {
                modelContext.delete(duplicate)
            }
            if records.count > 1 {
                try modelContext.save()
            }
            if let record = records.first {
                guard let snapshot = Self.decodeRoomSnapshot(record.snapshotData) else {
                    AppLog.log("⚠️ room snapshot corrupt for %@ - deleting", userId)
                    modelContext.delete(record)
                    try modelContext.save()
                    return nil
                }
                return snapshot
            }
            return migrateLegacyRoomSnapshotIfNeeded(userId: userId)
        } catch {
            ErrorReporter.capture(error, context: "MatrixSession.loadRoomSnapshot")
            AppLog.log("⚠️ room snapshot load failed for %@: %@", userId, String(describing: error))
            return nil
        }
    }

    private func migrateLegacyRoomSnapshotIfNeeded(userId: String) -> StoredRoomSnapshot? {
        let key = Self.legacyRoomSnapshotKey(userId)
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        defer { UserDefaults.standard.removeObject(forKey: key) }
        guard let snapshot = Self.decodeRoomSnapshot(data) else {
            AppLog.log("⚠️ legacy room snapshot corrupt for %@ - deleting", userId)
            return nil
        }
        saveRoomSnapshot(snapshot, userId: userId)
        AppLog.log("📋 migrated legacy room snapshot to SwiftData rooms=%d", snapshot.roomOrder.count)
        return snapshot
    }

    private func removeRoomSnapshot(userId: String?) {
        guard let userId else { return }
        UserDefaults.standard.removeObject(forKey: Self.legacyRoomSnapshotKey(userId))
        guard let modelContext else { return }
        do {
            let records = try modelContext.fetch(Self.roomSnapshotDescriptor(userId: userId))
            for record in records {
                modelContext.delete(record)
            }
            if !records.isEmpty {
                try modelContext.save()
            }
        } catch {
            ErrorReporter.capture(error, context: "MatrixSession.removeRoomSnapshot")
            AppLog.log("⚠️ room snapshot remove failed for %@: %@", userId, String(describing: error))
        }
    }

    private func currentRoomSnapshot() -> StoredRoomSnapshot {
        StoredRoomSnapshot(
            roomOrder: roomOrder,
            roomMembers: roomMembers,
            roomNames: roomNames,
            spaceRooms: Array(spaceRooms).sorted(),
            encryptedRooms: Array(encryptedRooms).sorted(),
            roomKinds: roomKinds,
            pinnedRoomIds: pinnedRoomIds,
            mutedRoomIds: Array(mutedRoomIds).sorted(),
            activeRoomId: activeRoomId
        )
    }

    private func saveRoomSnapshot() {
        guard let userId else { return }
        guard !roomOrder.isEmpty else {
            removeRoomSnapshot(userId: userId)
            return
        }
        saveRoomSnapshot(currentRoomSnapshot(), userId: userId)
    }

    @discardableResult
    private func restoreRoomSnapshotIfNeeded(userId: String) -> Bool {
        guard roomOrder.isEmpty, let snapshot = loadRoomSnapshot(userId: userId), !snapshot.roomOrder.isEmpty else {
            return false
        }
        roomOrder = snapshot.roomOrder
        roomMembers = snapshot.roomMembers
        roomNames = snapshot.roomNames
        spaceRooms = Set(snapshot.spaceRooms)
        encryptedRooms = Set(snapshot.encryptedRooms)
        roomKinds = snapshot.roomKinds
        pinnedRoomIds = Self.sanitizedPinnedRoomIds(snapshot.pinnedRoomIds)
        mutedRoomIds = Set(snapshot.mutedRoomIds)
        if let active = snapshot.activeRoomId, snapshot.roomOrder.contains(active) {
            activeRoomId = active
        }
        let restoredActiveRoomId = activeRoomId
        controlRoomId = nil
        rebuildRoomList()
        applyAutoOpen()
        if activeRoomId == restoredActiveRoomId {
            onActiveRoomChange?(activeRoomId)
        }
        updateSetupPhase()
        AppLog.log("📋 restored room snapshot rooms=%d active=%@", roomOrder.count, activeRoomId ?? "nil")
        return true
    }

    private func restoreCryptoStateForRoomSnapshot() {
        guard let crypto, let userId, !roomOrder.isEmpty else { return }
        for roomId in encryptedRooms {
            do {
                try crypto.markRoomEncrypted(roomId)
            } catch {
                ErrorReporter.capture(error, context: "MatrixSession.restoreRoomEncryption")
                AppLog.log("⚙️ restore room encryption failed for %@: %@", roomId, error.localizedDescription)
            }
        }
        let snapshotUsers = Set(roomMembers.values.flatMap { $0 }).filter { $0 != userId }
        let newUsers = snapshotUsers.filter { !trackedUsers.contains($0) }
        guard !newUsers.isEmpty else { return }
        do {
            try crypto.updateTrackedUsers(Array(newUsers))
            trackedUsers.formUnion(newUsers)
            AppLog.debug("🔑 restored tracking for %d snapshot user(s)", newUsers.count)
        } catch {
            ErrorReporter.capture(error, context: "MatrixSession.restoreTrackedUsers")
            AppLog.log("⚙️ restore tracked users failed: %@", error.localizedDescription)
        }
    }

    /// Pure D.1 to-device-cursor decision (unit-tested). Given one frame, returns
    /// the to-device cursor to persist + ack: advance to the frame's cursor ONLY
    /// if its keys were durably persisted (`cryptoPersisted`); otherwise carry the
    /// last good value forward. A frame with no to-device section (`frame == nil`)
    /// or one whose crypto persist failed must NOT advance the cursor past unsaved
    /// keys. Returns nil only until the first batch is durably persisted.
    nonisolated static func resolveToDevicePos(cryptoPersisted: Bool, frame: String?, last: String?) -> String? {
        if cryptoPersisted, let frame { return frame }
        return last
    }

    nonisolated static func sortedRooms(_ rooms: [RoomSummary], pinnedRoomIds: [String]) -> [RoomSummary] {
        let sanitized = sanitizedPinnedRoomIds(pinnedRoomIds)
        let pinnedOrder = Dictionary(uniqueKeysWithValues: sanitized.enumerated().map { ($0.element, $0.offset) })
        return rooms.enumerated().sorted { lhs, rhs in
            let leftPinned = pinnedOrder[lhs.element.id]
            let rightPinned = pinnedOrder[rhs.element.id]
            switch (leftPinned, rightPinned) {
            case let (left?, right?):
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    nonisolated static func sanitizedPinnedRoomIds(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for id in ids where !id.isEmpty && id.count <= 255 && seen.insert(id).inserted {
            out.append(id)
        }
        return out
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
