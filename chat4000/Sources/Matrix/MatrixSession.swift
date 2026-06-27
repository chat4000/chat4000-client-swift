import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
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
            AppLog.log("🔌 connection: %@ → %@", String(describing: oldValue), String(describing: connectionState))
            onConnectionStateChange?(connectionState)
            // Just came up → flush anything composed while we were offline.
            if connectionState == .connected { drainOutbox() }
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
    private(set) var setupPhase: SetupPhase = .connecting {
        didSet {
            guard oldValue != setupPhase else { return }
            let now = Date()
            let dwell = setupPhaseChangedAt.map { now.timeIntervalSince($0) } ?? 0
            // Every "Setting up" step transition, with how long the PREVIOUS step
            // took and the inputs that gate the next one. Lets a pulled log show
            // exactly where pairing spends its time / gets stuck.
            AppLog.log("🪜 setup step: %@ → %@ (%.1fs in prev) progress=%.0f%% conn=%@ wsReady=%@ control=%@ rooms=%d invites=%d",
                       oldValue.label, setupPhase.label, dwell,
                       setupPhase.progress * 100, String(describing: connectionState),
                       String(isWorkspaceReady), controlRoomId ?? "nil", rooms.count, joinedInviteAttempts.count)
            setupPhaseChangedAt = now
        }
    }
    /// Wall-clock of the last `setupPhase` change — drives per-step dwell logging.
    @ObservationIgnored private var setupPhaseChangedAt: Date?
    /// True once we've been stuck in a plugin-dependent setup phase
    /// (`waitingForPlugin` / `joiningWorkspace`) past `setupStallTimeout`. The
    /// plugin must invite us and key the control room; if it crashed mid-pairing,
    /// neither ever arrives and the "Setting up" progress screen would otherwise
    /// spin forever. The UI swaps the spinner for an actionable "plugin isn't
    /// responding" state when this flips true.
    private(set) var setupStalled = false
    @ObservationIgnored private var setupStallTask: Task<Void, Never>?
    /// How long to wait in a plugin-dependent setup phase before surfacing the
    /// stall. Deliberately LONG (6 min): on a fresh pair / re-install the plugin's
    /// Hermes gateway can take several minutes to become usable — a clean gateway
    /// boot includes a ~10–15s old-process-takeover wait plus slow MCP-tool
    /// discovery on the critical path (hermes-agent `gateway/run.py`), so the
    /// control-room invite + plugin keys legitimately arrive minutes late. 45s
    /// declared "plugin isn't responding" while the gateway was still booting; 6 min
    /// only catches the genuinely-no-show (crashed) case. Non-destructive: we keep
    /// waiting and still auto-advance the instant the invite/keys land.
    static let setupStallTimeout: Duration = .seconds(360)
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
    /// F2 (protocol F.2.3): the cross-process crypto-store lock, wired to the
    /// App-Group sidecar lockfile + generation file. nil when there is no App
    /// Group (no NSE world) — `CryptoEngine` then runs store calls directly, the
    /// pre-F2 single-process behavior. Built once and reused across reconnects so
    /// every `CryptoEngine` for this session shares the same lock instance.
    @ObservationIgnored private lazy var storeLock: CryptoStoreLock? = Self.makeStoreLock()

    /// Build the App-Group-backed `CryptoStoreLock`, or nil if the App Group is
    /// unavailable (entitlement missing → single-process fallback, no NSE).
    private static func makeStoreLock() -> CryptoStoreLock? {
        let namespace = AppEnvironment.current.storageNamespace
        guard let lockfileURL = AppGroup.lockfileURL(namespace: namespace),
              let generationURL = AppGroup.generationURL(namespace: namespace) else {
            return nil
        }
        return CryptoStoreLock(lockfileURL: lockfileURL, generationURL: generationURL)
    }
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
    /// `sync_start` on reconnect (the resume case). It is NOT what a `sync_ack`
    /// carries — the ack echoes the acked frame's `to_device_pos` exactly (never
    /// this carried-forward value). nil until the first to-device batch is
    /// durably persisted.
    @ObservationIgnored private var lastToDevicePos: String?
    @ObservationIgnored private var pushTokenObserver: NSObjectProtocol?

    // MARK: - UI foreground state (protocol D.4)
    //
    // The single source of truth for THIS device's `foreground` value, reported
    // to the gateway as `ui_state` (D.1) so it can suppress cross-device push
    // duplicates (D.4). `foreground == true` ONLY when the app is frontmost AND
    // (on iOS) the device is unlocked — a human can presently see the screen.
    // Backgrounded, inactive, not-frontmost, or locked → `false`.
    //
    // `appActive` is driven by the per-platform "app is frontmost" signal: on iOS
    // the SwiftUI scene phase (active vs. not); on macOS the AppKit application
    // active state (`NSApplication.didBecomeActive`/`didResignActive`), because
    // SwiftUI's `scenePhase` does NOT reliably leave `.active` on app-switch for
    // an AppKit-backed Mac app — Cmd-Tab / minimize / losing key would otherwise
    // leave `appActive == true` and a backgrounded Mac would still report itself
    // foreground, suppressing the cross-device push (the bug this fixes).
    // `deviceUnlocked` tracks the per-platform screen-lock signal
    // (D.4): on iOS via the protected-data notifications (the standard "device
    // locked" proxy — file protection becomes unavailable on lock); on macOS via
    // the `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` distributed
    // notifications, so a screen-locked or screensaver'd Mac reports
    // `foreground = false` even while the app stays the active application.
    // `currentForeground` is their conjunction. Both default to background until
    // the scene phase first reports active — the safe direction (D.4: an extra
    // silent wake, never a missed one).
    @ObservationIgnored private var appActive = false
    @ObservationIgnored private var deviceUnlocked = true
    /// The last `foreground` value reported to the gateway, so we send an
    /// unsolicited `ui_state` ONLY on an actual flip (D.4), not on every nudge.
    @ObservationIgnored private var lastReportedForeground: Bool?
    @ObservationIgnored private var protectedDataUnavailableObserver: NSObjectProtocol?
    @ObservationIgnored private var protectedDataAvailableObserver: NSObjectProtocol?
    @ObservationIgnored private var screenLockedObserver: NSObjectProtocol?
    @ObservationIgnored private var screenUnlockedObserver: NSObjectProtocol?
    @ObservationIgnored private var appDidBecomeActiveObserver: NSObjectProtocol?
    @ObservationIgnored private var appDidResignActiveObserver: NSObjectProtocol?
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
        observeDeviceLockState()
    }

    /// Track the screen-lock state per platform (protocol D.4: `foreground`
    /// requires the screen unlocked). The matching notifications fire on every
    /// lock/unlock and the closures hop to the `@MainActor` to mutate state and
    /// re-report.
    ///
    /// - iOS: `UIApplication.isProtectedDataAvailable` is the standard "device
    ///   unlocked" proxy — complete-protection files are inaccessible while
    ///   locked and become accessible on unlock — with the matching
    ///   protected-data notifications.
    /// - macOS: the `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`
    ///   distributed notifications (`DistributedNotificationCenter`). A locked or
    ///   screensaver'd Mac is NOT foreground even while the app remains the active
    ///   application. There is no synchronous "is the screen locked right now?"
    ///   API, so we keep the initial `deviceUnlocked = true` default and rely on
    ///   the notifications to flip it; the first lock after launch reports the
    ///   flip, and the safe-direction default means at worst an extra wake while
    ///   genuinely unlocked, never a missed one (D.4).
    private func observeDeviceLockState() {
        #if canImport(UIKit)
        deviceUnlocked = UIApplication.shared.isProtectedDataAvailable
        protectedDataUnavailableObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateDeviceUnlocked(false) }
        }
        protectedDataAvailableObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateDeviceUnlocked(true) }
        }
        #elseif canImport(AppKit)
        let center: DistributedNotificationCenter = .default()
        screenLockedObserver = center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateDeviceUnlocked(false) }
        }
        screenUnlockedObserver = center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateDeviceUnlocked(true) }
        }
        // App-active dimension on macOS. SwiftUI's `scenePhase` is unreliable on
        // app-switch for an AppKit-backed app (it stays `.active` when the app is
        // Cmd-Tabbed away / minimized / loses key), so the scene-phase path in
        // chat4000App can never flip `appActive` to false on deactivation. Drive
        // it from AppKit's own application-active notifications instead, and seed
        // the current value from `NSApplication.shared.isActive` at startup so a
        // session created while already-backgrounded starts non-foreground. Both
        // route through `setAppActive`, which reports the flip to the gateway.
        appActive = NSApplication.shared.isActive
        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setAppActive(true) }
        }
        appDidResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setAppActive(false) }
        }
        #endif
    }

    private func updateDeviceUnlocked(_ unlocked: Bool) {
        guard deviceUnlocked != unlocked else { return }
        deviceUnlocked = unlocked
        reportForegroundStateIfChanged()
    }

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// True if paired credentials are persisted (drives launch routing).
    var isPaired: Bool { MatrixCredentialStore.load() != nil }

    // MARK: - Pairing / connect

    func pair(code: String) async {
        // A pairing is a fresh start. A pairing link can arrive while a previous
        // session is still CONNECTED (handleIncomingURL starts pairing from any
        // screen), so tear the old transport down first — otherwise the old
        // socket keeps syncing into the reset state (re-saving the room snapshot
        // we're about to remove) and `wipeCryptoStore` below would yank the key
        // DB out from under a live CryptoEngine. `GatewayClient.disconnect()`
        // suppresses `onClosed`, so this never triggers a spurious reconnect.
        // Then clear any previous session's rooms, active chat, and cached
        // events so we never surface an old session the user is no longer
        // connected to.
        gateway?.disconnect()
        gateway = nil
        crypto = nil
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
            // One user per plugin (protocol C.1/C.2): every redeem adds a DEVICE
            // to the same fixed user, so this user_id may have paired on this
            // phone before. The persisted sync cursors and room snapshot belong
            // to that PREVIOUS device — a new device has no cursor (D.1: the
            // device is the source of truth for both) — so drop them, or
            // startClient would resume the old device's positions on the new
            // device's connection.
            UserDefaults.standard.removeObject(forKey: Self.syncPosKey(redeemed.userId))
            UserDefaults.standard.removeObject(forKey: Self.toDevicePosKey(redeemed.userId))
            removeRoomSnapshot(userId: redeemed.userId)
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

    /// Restore a paired session on launch / foreground. Idempotent: re-entrant
    /// calls while we're already up, bringing the socket up, or reconnecting are
    /// ignored, so the two `setupMatrix` onAppear paths (ModelContextBinder +
    /// ChatShell) and the foreground handler can never open two clients. Restores
    /// local state from disk FIRST so the chat is already on screen; the socket then
    /// comes up in the background.
    func connect() async {
        restoreFromDisk()
        switch connectionState {
        case .connected, .connecting, .reconnecting:
            return
        case .disconnected, .failed:
            break
        }
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

    /// Build the gateway + crypto from persisted creds WITHOUT any networking, so a
    /// returning user's room list + history render immediately (chat shown before
    /// the socket). The crypto store is local (sqlite) and `GatewayClient.connect()`
    /// is the only network call, so both can be constructed offline. Idempotent — a
    /// no-op once a transport exists or a user is already in memory (e.g. a live
    /// reconnect, which `reconnectLoop` owns). Returns true when a session is now
    /// restored in memory.
    @discardableResult
    func restoreFromDisk() -> Bool {
        guard gateway == nil, crypto == nil, userId == nil else { return userId != nil }
        guard let stored = MatrixCredentialStore.load(),
              let url = URL(string: stored.gatewayURL) else {
            return false
        }
        let gateway = makeGateway(stored, url: url)
        let crypto: CryptoEngine
        do {
            crypto = try CryptoEngine(
                userId: stored.userId,
                deviceId: stored.deviceId,
                storePath: MatrixEnvironment.current.cryptoStorePath,
                gateway: gateway,
                storeLock: storeLock
            )
        } catch {
            // Crypto store unopenable offline — fall back to the online path, which
            // rebuilds from scratch once the socket is up. Not fatal: just no instant
            // chat this launch. (`gateway` is a local that is simply discarded; it was
            // never connected, so there is nothing to tear down.)
            ErrorReporter.capture(error, context: "MatrixSession.restoreFromDisk")
            AppLog.log("⚙️ offline restore skipped (crypto open failed): \(error)")
            return false
        }
        creds = stored
        userId = stored.userId
        mediaBaseURL = MatrixEnvironment.mediaBaseURL(fromGatewayURL: stored.gatewayURL)
        self.gateway = gateway
        self.crypto = crypto
        restoreRoomSnapshotIfNeeded(userId: stored.userId)
        restoreCryptoStateForRoomSnapshot()
        AppLog.log("📴 offline restore: user=%@ rooms=%d (chat shown before socket)",
                   stored.userId, roomOrder.count)
        return true
    }

    /// Construct (but DO NOT connect) a fully-wired `GatewayClient` for `stored`.
    /// Shared by the offline restore and the online start paths so the
    /// sync/close/reauth handlers are identical in both.
    private func makeGateway(_ stored: MatrixCredentialStore.Stored, url: URL) -> GatewayClient {
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
        gateway.onSyncReset = { [weak self] cursors in
            Task { @MainActor in self?.handleSyncReset(cursors: cursors) }
        }
        gateway.onClosed = { [weak self] in
            Task { @MainActor in await self?.handleSocketClosed() }
        }
        // D.1/D.4: answer every `ui_ping` with the live foreground value. Both
        // this session and the gateway are `@MainActor`, so the read is safe and
        // synchronous. `false` when unwired is the safe default (extra wake, not a
        // missed one).
        gateway.foregroundStateProvider = { [weak self] in self?.currentForeground ?? false }
        // A fresh socket starts with no reported state — re-arm the on-change
        // detector so the first scene-phase/lock flip after (re)connect is sent
        // unsolicited rather than suppressed as "unchanged".
        lastReportedForeground = nil
        return gateway
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
        // Reuse the transport built offline by `restoreFromDisk` (launch fast-path);
        // otherwise build it now (fresh pair / reconnect, where both were cleared).
        let reused = self.gateway != nil
        let gateway = self.gateway ?? makeGateway(stored, url: url)
        self.gateway = gateway

        AppLog.log("🪜 connecting: opening gateway socket → %@ (reused_transport=%@)", stored.gatewayURL, String(reused))
        let auth = try await gateway.connect()
        AppLog.log("🪜 connecting: auth OK — user=%@ device=%@", auth.userId, auth.deviceId)
        // Connected as a DIFFERENT account than the one currently in memory → the
        // previous session's rooms/active chat/cached events are stale. Clear them
        // so a reconnect to a new session doesn't surface the old chat. (A plain
        // reconnect to the SAME user keeps its state and resumes.)
        if let previous = userId, previous != auth.userId {
            AppLog.log("🔄 identity changed %@ → %@; clearing stale session state", previous, auth.userId)
            resetSessionState()
        }
        // Reuse the offline-built OlmMachine when the authed identity matches the
        // creds it was opened with (avoids opening the crypto sqlite twice); else
        // build it now for the authed identity (fresh pair, or an identity change).
        let crypto: CryptoEngine
        if let existing = self.crypto, auth.userId == stored.userId, auth.deviceId == stored.deviceId {
            AppLog.log("🪜 connecting: reusing offline-built crypto (device=%@)", auth.deviceId)
            crypto = existing
        } else {
            AppLog.log("🪜 connecting: building fresh crypto store (user=%@ device=%@)", auth.userId, auth.deviceId)
            crypto = try CryptoEngine(
                userId: auth.userId,
                deviceId: auth.deviceId,
                storePath: MatrixEnvironment.current.cryptoStorePath,
                gateway: gateway,
                storeLock: storeLock
            )
        }

        self.crypto = crypto
        self.userId = auth.userId
        self.reconnectAttempts = 0
        self.connectionState = .connected
        if setupPhase.rawValue < SetupPhase.syncing.rawValue { setupPhase = .syncing }
        AppLog.log("✅ Matrix gateway connected as \(auth.userId) device \(auth.deviceId)")
        // D.4: the gateway seeds this device's foreground entry to `false` on
        // auth; report our true current state right away so suppression is
        // accurate without waiting for the first `ui_ping` (the on-change detector
        // was re-armed in `makeGateway`). Subsequent flips report unsolicited;
        // steady state is covered by the ping reply.
        reportForegroundStateIfChanged()

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
        // Stamp the live-sync heartbeat (F.2.1b): while the app is syncing, the NSE
        // must NOT also drain to-device (single-writer on the shared cursor).
        Self.stampLiveSyncHeartbeat(userId: userId)
        for r in sync.rooms {
            AppLog.log("🏠 room %@ kind=%@ space=%@ invite=%@ enc=%@ members=%d tl=%d",
                       r.id, r.roomKind ?? "nil", String(r.isSpace), String(r.isInvite),
                       String(r.isEncrypted), r.members.count, r.timeline.count)
        }
        // STEP 1 — FEED ONLY (no network drain). Persist this frame's e2ee state
        // (to-device room keys, device lists, OTK counts) into the crypto store.
        // `cryptoPersisted` gates the to-device cursor (D.1, "Sync cursor & key
        // delivery"): we may advance `to_device_pos` ONLY when this frame's keys are
        // confirmed durably on disk — `receiveSyncChangesIntoStore` returning without
        // throwing is that confirmation. A throw means we CANNOT confirm the keys are
        // saved, so we hold the cursor and let the homeserver re-deliver next sync
        // (idempotent re-import) — never ack it lost.
        //
        // The network DRAIN (keys/query, keys/claim, room-key shares) is deliberately
        // SPLIT OUT to STEP 3 — AFTER processRoom has tracked any newly-seen members.
        // Draining here (the old `processSync`) sent a freshly-seen plugin's
        // keys/query a full sync cycle late (~30s), because we drained BEFORE we
        // knew the plugin existed.
        var cryptoPersisted = true
        do { try crypto?.receiveSyncChangesIntoStore(sync) } catch {
            cryptoPersisted = false
            ErrorReporter.capture(error, context: "MatrixSession.receiveSyncChanges")
            AppLog.log("⚙️ crypto.receiveSyncChanges failed: \(error)")
        }

        // STEP 2 — discover rooms + track new members (updateTrackedUsers), decrypt
        // and dispatch events.
        for room in sync.rooms { await processRoom(room) }

        // STEP 3 — RECONCILE: drive crypto to a fixpoint now that new members are
        // tracked, so a freshly-seen plugin's keys/query goes out THIS cycle instead
        // of waiting for the next sync frame (the ~30s "Joining your workspace" fix).
        // Idempotent + coalesced inside CryptoEngine.
        await reconcileCrypto(reason: "post-sync")

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
        // A sync may have just keyed a room (made it reachable) — flush any sends
        // that were queued waiting on that.
        drainOutbox()

        // Durable-ack BOTH cursors (protocol D.1, "Sync cursor & key delivery"):
        // processSync persisted the to-device Megolm keys + crypto state and the
        // dispatch above persisted messages, so it's now safe to let the gateway
        // advance upstream (and the homeserver delete the acked to-device). The
        // gateway holds the cursors until this arrives — without it, sync never
        // advances and no new messages are delivered.
        if let pos = sync.pos {
            // Resolve the to-device cursor to persist: advance to this frame's
            // `to_device_pos` ONLY if its keys were durably persisted; otherwise
            // carry the last good value forward (a frame with no to-device
            // section, or one whose crypto persist failed, must not advance the
            // DURABLE cursor past unsaved keys). Persist to durable storage AFTER
            // the crypto-store write above, then ack — never before, so a crash
            // can only ever lose the cursor (→ harmless re-delivery), never
            // persist a cursor ahead of keys that aren't saved. This carried-
            // forward durable value is what `sync_start` resends on reconnect.
            let nextToDevicePos = Self.resolveToDevicePos(
                cryptoPersisted: cryptoPersisted, frame: sync.toDevicePos, last: lastToDevicePos)
            if let nextToDevicePos, nextToDevicePos != lastToDevicePos {
                Self.saveToDevicePos(nextToDevicePos, userId: userId)
            }
            lastToDevicePos = nextToDevicePos
            Self.saveSyncPos(pos, userId: userId)
            // The `sync_ack` to-device cursor is ECHO-EXACT (protocol D.1, "Device
            // rules"): it echoes THIS frame's `to_device_pos` exactly — present
            // iff the frame carried a to-device section, omitted otherwise — and
            // NEVER carries a previous durable value forward (the gateway
            // validates the echo against the cursor it sent and closes the socket
            // with `bad_sync_ack` on any mismatch). The carry-forward of the
            // durable cursor above is for `sync_start` resume ONLY, never the ack.
            // The "never ack a to-device cursor before its keys are durably saved"
            // rule still holds: if crypto failed to persist this frame's keys we
            // omit the echo (do not ack the cursor) and let the homeserver
            // re-deliver next sync.
            let ackToDevicePos = cryptoPersisted ? sync.toDevicePos : nil
            gateway?.syncAck(pos: pos, toDevicePos: ackToDevicePos)
        }
        resumeSyncWaiters()
    }

    /// THE crypto-reconcile entry point. Drives the OlmMachine's outgoing requests
    /// (keys/query for newly-tracked users, keys/claim, room-key shares) to a
    /// fixpoint. Call this from EVERY site that dirties the machine — the post-sync
    /// step, `updateTrackedUsers`, gossip — so crypto progress is event-driven and
    /// never gated on the next sync frame (the root cause of the ~30s pairing wait).
    /// `runOutgoingRequests` is coalesced + bounded, so calling this freely is safe.
    private func reconcileCrypto(reason: String) async {
        guard let crypto else { return }
        do {
            try await crypto.runOutgoingRequests()
        } catch AppError.cancelled {
            // Session tore down / reconnected mid-reconcile — fine; the next sync
            // (or reconnect) re-reconciles. Not an error.
            AppLog.debug("🔑 reconcile (%@) cancelled", reason)
        } catch {
            ErrorReporter.capture(error, context: "MatrixSession.reconcileCrypto")
            AppLog.log("🔑 reconcile (%@) failed: %@", reason, error.localizedDescription)
        }
    }

    /// Handle a `sync_reset` frame (protocol D.1/D.2 cursor-expiry recovery). The
    /// homeserver rejected the room cursor with `M_UNKNOWN_POS`; the gateway has
    /// ALREADY dropped the named cursor(s) and re-initialised upstream from scratch
    /// on this same socket. Our job is the device rule (D.2 "Device rule"):
    /// immediately discard EXACTLY the named cursor(s) from durable storage so a
    /// later reconnect cannot replay a stale `pos` (which would just re-trigger
    /// `M_UNKNOWN_POS`). We MUST NOT:
    ///   • tear down crypto state (the to-device stream is separate and durable),
    ///   • drop the to-device cursor unless it is itself named (a `pos_expired`
    ///     reset names `["pos"]` only), or
    ///   • send a new `sync_start` — the fresh `sync` frames are already streaming
    ///     on this socket and persist the new `pos` through the normal ack flow.
    func handleSyncReset(cursors: [String]) {
        let toClear = Self.durableCursorsToClear(named: cursors)
        AppLog.log("🔁 sync_reset: discarding durable cursors=%@ (named=%@) keeping crypto + unnamed cursors",
                   toClear.joined(separator: ","), cursors.joined(separator: ","))
        for cursor in toClear {
            switch cursor {
            case "pos":
                // Discard the room cursor so the next reconnect omits `pos` and
                // recovers room state from the homeserver's durable store.
                Self.clearSyncPos(userId: userId)
            case "to_device_pos":
                // Only reached if the gateway explicitly names the to-device cursor
                // (never for `pos_expired`). Discard the durable to-device cursor
                // and its in-memory carry-forward so neither replays it.
                Self.clearToDevicePos(userId: userId)
                lastToDevicePos = nil
            default:
                break
            }
        }
        // Deliberately NOT done: no crypto teardown, no `sync_start`, no touch of
        // any cursor that was not named.
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
        // Offline-gap backfill (missing-messages fix): when this catch-up timeline
        // is `limited`, the events between what we last saw and this window were
        // DROPPED by the list's `timeline_limit` truncation (the `chat4000.status`
        // heartbeat flood fills the window and pushes older USER messages out). Walk
        // `/messages` backward from `prev_batch` until we reconnect to known history,
        // then process the gap BEFORE the window so the timeline is contiguous —
        // nothing renders or acks until the whole gap is loaded into memory
        // (handleSync awaits processRoom, and the syncAck is last).
        let backfilled = room.isLimited ? await backfillGap(roomId: room.id, from: room.prevBatch) : []
        if !backfilled.isEmpty {
            AppLog.log("🕳️ prepending %d backfilled gap event(s) ahead of %@ window (tl=%d)",
                       backfilled.count, room.id, room.timeline.count)
        }
        for outer in backfilled + room.timeline {
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

    /// Backfill the offline gap above a TRUNCATED (`limited`) catch-up timeline.
    /// Walks `GET /rooms/{id}/messages?dir=b` backward from the room's `prev_batch`,
    /// collecting every dropped event (messages AND `chat4000.status` — the user
    /// wants all of it), until it reaches an event we've already processed
    /// (`seenEventIds`) → the gap is now contiguous with known history — or the
    /// room start (no further pagination token). No size cap, per the requirement
    /// to "load everything"; termination is by reaching known history, an empty
    /// chunk, or a non-advancing token (the only real infinite-loop guards). All
    /// requests ride the same gateway socket as `req`/`resp`. Returns the gap in
    /// CHRONOLOGICAL order (oldest→newest) so the caller can prepend it to the
    /// window and feed both through the normal decrypt → render path in order.
    private func backfillGap(roomId: String, from prevBatch: String?) async -> [SyncEvent] {
        guard let gateway else { return [] }
        guard let start = prevBatch, !start.isEmpty else {
            AppLog.log("🕳️ backfill skipped for %@ — limited but no prev_batch token", roomId)
            return []
        }
        // Percent-encode the pagination token as a query VALUE (the gateway forwards
        // the path verbatim to Tuwunel; tokens can contain `/`, `+`, etc.).
        let tokenAllowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let basePath = percentEncodePath("/_matrix/client/v3/rooms/\(roomId)/messages")
        var from = start
        var collected: [SyncEvent] = []   // accumulated newest-first across pages
        var page = 0
        while true {
            page += 1
            let encFrom = from.addingPercentEncoding(withAllowedCharacters: tokenAllowed) ?? from
            let path = "\(basePath)?dir=b&limit=200&from=\(encFrom)"
            let body: Data
            do {
                let (status, data) = try await gateway.request(method: "GET", path: path)
                guard (200..<300).contains(status) else {
                    AppLog.log("🕳️ backfill %@ page=%d HTTP %d — stopping", roomId, page, status)
                    break
                }
                body = data
            } catch AppError.cancelled {
                // Expected: the session tore down / reconnected mid-backfill. The
                // gap is untouched; the next `limited` catch-up re-triggers this.
                AppLog.log("🕳️ backfill %@ page=%d cancelled — stopping", roomId, page)
                break
            } catch {
                ErrorReporter.capture(error, context: "MatrixSession.backfillGap")
                AppLog.log("🕳️ backfill %@ page=%d failed: %@ — stopping", roomId, page, error.localizedDescription)
                break
            }
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                AppLog.log("🕳️ backfill %@ page=%d bad JSON — stopping", roomId, page)
                break
            }
            let chunk = SyncModel.parseMessagesChunk(obj["chunk"])   // newest-first (dir=b)
            var hitKnown = false
            for event in chunk {
                if let eid = event.eventId, seenEventIds.contains(eid) { hitKnown = true; break }
                collected.append(event)
            }
            let end = obj["end"] as? String
            AppLog.log("🕳️ backfill %@ page=%d chunk=%d gapTotal=%d hitKnown=%@ end=%@",
                       roomId, page, chunk.count, collected.count, String(hitKnown), end ?? "nil")
            if hitKnown { break }
            // Stop at room start / no-progress / empty page (infinite-loop guards).
            guard let end, !end.isEmpty, end != from, !chunk.isEmpty else { break }
            from = end
        }
        AppLog.log("🕳️ backfill %@ done: %d gap event(s) over %d page(s)", roomId, collected.count, page)
        return collected.reversed()   // → oldest→newest, contiguous with the window
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
        let prevReady = isWorkspaceReady
        isWorkspaceReady = controlRoomId.map { isRoomReady($0) } ?? false
        if isWorkspaceReady != prevReady {
            AppLog.log("🪜 workspace-ready: %@ → %@ (control=%@ members=%d) — this is the gate for 'Joining your workspace'",
                       String(prevReady), String(isWorkspaceReady), controlRoomId ?? "nil",
                       controlRoomId.flatMap { roomMembers[$0]?.count } ?? 0)
        }
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
        guard let crypto, let userId else {
            AppLog.debug("🔑 room-ready? %@ → false (no crypto/userId yet)", roomId)
            return false
        }
        let recipients = roomMembers[roomId] ?? []
        let reachable = crypto.isRoomReachable(recipients: recipients, selfUserId: userId)
        // The decisive check during "Joining your workspace": is the PLUGIN's device
        // known + has an Olm session? false here = we're waiting on the plugin's keys.
        AppLog.debug("🔑 room-ready? %@ reachable=%@ recipients=%d", roomId, String(reachable), recipients.count)
        return reachable
    }

    /// Recompute the first-run progress phase from current room state.
    /// G4: true once the workspace has ever been set up (a control/session room
    /// existed). On relaunch we use this to SKIP the first-run setup/"connecting"
    /// screen and go straight to the chat, instead of flashing it every cold start.
    var hasCompletedFirstSetup: Bool { UserDefaults.standard.bool(forKey: Self.firstSetupKey) }
    private static let firstSetupKey = "chat4000.didCompleteFirstSetup"

    private func updateSetupPhase() {
        let previous = setupPhase
        AppLog.debug("🪜 setup-eval: wsReady=%@ rooms=%d control=%@ invites=%d (current=%@)",
                     String(isWorkspaceReady), rooms.count, controlRoomId ?? "nil",
                     joinedInviteAttempts.count, previous.label)
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

    /// Open a room in response to a notification TAP (protocol F). Opens immediately
    /// if the room is already loaded; otherwise it's remembered and opened on the
    /// next sync — covers a cold launch or a brand-new session room not yet synced —
    /// via the same `autoOpen` path used after `session.new`.
    func openRoomFromPush(_ roomId: String) {
        guard !roomId.isEmpty else { return }
        AppLog.log("🎯 openRoomFromPush room=%@ loaded=%@", roomId,
                   rooms.contains(where: { $0.id == roomId }) ? "yes" : "no")
        autoOpenRoomId = roomId
        applyAutoOpen()
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

    // MARK: - Sending (outbox)

    /// One queued outbound message's payload. The DURABLE copy is the `.sending`
    /// `ChatMessage` row (RoomViewModel re-enqueues stranded rows on history load),
    /// so a send survives the app being killed mid-flight; this carries the payload
    /// for the live session.
    enum OutboxContent {
        case text(String)
        case image(Data, mimeType: String)
        case audio(Data, mimeType: String, durationMs: Int)
    }

    private struct OutboxItem {
        let localId: String
        let roomId: String
        let content: OutboxContent
    }

    @ObservationIgnored private var outbox: [OutboxItem] = []
    /// Local ids of sends currently awaiting an event_id (so a re-enqueue or a drain
    /// can never fire the same row twice within a session).
    @ObservationIgnored private var inFlightSends: Set<String> = []

    /// Queue an outbound message and try to flush immediately. Held when we're
    /// offline or the room isn't keyed yet, and flushed in order the moment both are
    /// true — so a message composed before the socket is up still goes out, exactly
    /// once it can. `localId` correlates the returned event_id back to the caller's
    /// local row (for the read tick). Idempotent per `localId`.
    func enqueueSend(_ content: OutboxContent, roomId: String, localId: String) {
        guard !inFlightSends.contains(localId),
              !outbox.contains(where: { $0.localId == localId }) else { return }
        outbox.append(OutboxItem(localId: localId, roomId: roomId, content: content))
        drainOutbox()
    }

    /// Flush every queued send that can go now: we're connected AND the target room
    /// is keyed (so it encrypts to the plugin, not to 0 devices — the I2 gate).
    /// Order-preserving; an item that can't go yet stays queued for the next drain
    /// (on `.connected`, or after a sync makes its room reachable).
    private func drainOutbox() {
        guard connectionState == .connected, crypto != nil, !outbox.isEmpty else { return }
        for item in outbox where !inFlightSends.contains(item.localId) {
            guard isRoomReady(item.roomId) else { continue }
            inFlightSends.insert(item.localId)
            Task { [weak self] in await self?.deliverOutboxItem(item) }
        }
    }

    private func deliverOutboxItem(_ item: OutboxItem) async {
        // Use the row's local id as the send transaction id so a re-send after a
        // crash is idempotent at the homeserver (exactly-once — no duplicate event).
        let txnId = item.localId
        let eventId: String?
        switch item.content {
        case .text(let text):
            eventId = await deliverText(text, roomId: item.roomId, txnId: txnId)
        case .image(let data, let mimeType):
            eventId = await deliverMedia(
                data, mimeType: mimeType, roomId: item.roomId, txnId: txnId,
                msgtype: "m.image", filename: Self.imageFilename(mimeType: mimeType),
                info: ["mimetype": mimeType, "size": data.count])
        case .audio(let data, let mimeType, let durationMs):
            eventId = await deliverMedia(
                data, mimeType: mimeType, roomId: item.roomId, txnId: txnId,
                msgtype: "m.audio", filename: "voice.m4a",
                info: ["mimetype": mimeType, "size": data.count, "duration": durationMs])
        }
        inFlightSends.remove(item.localId)
        guard let eventId else {
            // Failed (offline / transient / not-yet-keyed) — leave it queued; the
            // next drain retries. The row stays `.sending`.
            return
        }
        outbox.removeAll { $0.localId == item.localId }
        onSentEventId?(item.localId, eventId)
    }

    /// Encrypt + send plain text. Returns the homeserver event_id on success, nil on
    /// any (expected, offline-ish) failure so the outbox can retry.
    private func deliverText(_ text: String, roomId: String, txnId: String) async -> String? {
        do {
            return try await crypto?.encryptAndSend(
                roomId: roomId,
                recipients: roomMembers[roomId] ?? [],
                content: ["msgtype": "m.text", "body": text],
                transactionId: txnId
            )
        } catch {
            ErrorReporter.capture(error, context: "MatrixSession.deliverText")
            AppLog.log("⚠️ Matrix text send failed: \(error)")
            return nil
        }
    }

    nonisolated static func imageFilename(mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": return "image.png"
        case "image/gif": return "image.gif"
        case "image/heic": return "image.heic"
        case "image/heif": return "image.heif"
        case "image/webp": return "image.webp"
        default: return "image.jpg"
        }
    }

    /// Encrypt the blob, upload the ciphertext (protocol D.3), and send an
    /// `m.image`/`m.audio` referencing the resulting `mxc://` + decryption key.
    /// Returns the event_id on success, nil on failure (so the outbox can retry).
    private func deliverMedia(
        _ data: Data, mimeType: String, roomId: String, txnId: String,
        msgtype: String, filename: String, info: [String: Any]
    ) async -> String? {
        guard let creds, let mediaBase = mediaBaseURL else {
            AppLog.log("⚠️ media send held — no media base / creds yet")
            return nil
        }
        do {
            let file = try await MatrixMedia.encryptAndUpload(
                data, mediaBaseURL: mediaBase, accessToken: creds.accessToken, filename: filename)
            let content: [String: Any] = ["msgtype": msgtype, "body": filename, "file": file, "info": info]
            return try await crypto?.encryptAndSend(
                roomId: roomId, recipients: roomMembers[roomId] ?? [], content: content,
                transactionId: txnId)
        } catch {
            ErrorReporter.capture(error, context: "MatrixSession.deliverMedia")
            AppLog.log("⚠️ Matrix media send failed: \(error)")
            return nil
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

    /// Bumped to ask the UI to open "rename" for the active session — backs the
    /// macOS Cmd+R shortcut. The sidebar observes this token and presents its
    /// rename alert pre-filled with the active room's name. No-op with no active
    /// room (e.g. before the first session exists).
    private(set) var renameActiveRequestToken: Int = 0

    func requestRenameActiveSession() {
        guard activeRoomId != nil else { return }
        renameActiveRequestToken += 1
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
        // F2 (protocol F): carry `account_id` on the pusher `data` so the wake
        // names which account on this device the NSE should fetch+decrypt for.
        // (One device = one account, so this is the single stored account.)
        var data: [String: Any] = [
            "url": MatrixEnvironment.current.notificationPushURL,
            "format": "event_id_only"
        ]
        if let creds {
            data["account_id"] = SharedCredentials.accountId(userId: creds.userId, deviceId: creds.deviceId)
        }
        let body: [String: Any] = [
            "pushkey": token,
            "kind": "http",
            "app_id": appId,
            "app_display_name": "chat4000",
            "device_display_name": Self.deviceDisplayName,
            "lang": "en",
            "data": data
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
        let before = backgroundNotifyCount
        AppLog.log("🔔 [push] backgroundWake ENTER appState=%@ backgrounded=%@ conn=%@",
                   appStateString, isBackgrounded ? "true" : "false", "\(connectionState)")
        if connectionState != .connected { await connect() }
        guard connectionState == .connected else {
            AppLog.log("🔔 [push] backgroundWake ABORT reason=not_connected conn=%@", "\(connectionState)")
            return false
        }
        await waitForSync(timeout: .seconds(25))
        let posted = backgroundNotifyCount - before
        AppLog.log("🔔 [push] backgroundWake EXIT appState=%@ backgrounded=%@ posted=%ld",
                   appStateString, isBackgrounded ? "true" : "false", posted)
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

    // MARK: - UI foreground state reporting (protocol D.1 / D.4)

    /// This device's current `foreground` value (protocol D.4): the app is
    /// frontmost/active AND the screen is unlocked. On iOS "unlocked" is the
    /// protected-data signal; on macOS it is the `screenIsLocked` /
    /// `screenIsUnlocked` distributed notifications, so a screen-locked Mac is not
    /// foreground even while the app stays the active application.
    private var currentForeground: Bool { appActive && deviceUnlocked }

    /// Drive the app-active dimension from the SwiftUI scene phase (the app calls
    /// this from its `onChange(of: scenePhase)`): `.active` → `true`; `.inactive`
    /// / `.background` (and macOS resign-active) → `false`. Combined with the lock
    /// state to compute `foreground`, then reported to the gateway on any flip.
    func setAppActive(_ active: Bool) {
        guard appActive != active else { return }
        appActive = active
        reportForegroundStateIfChanged()
    }

    /// Send an unsolicited `ui_state` to the gateway IFF the computed foreground
    /// value actually flipped since the last report (protocol D.4: report the
    /// change immediately, without waiting for the next `ui_ping`). A no-op when
    /// the value is unchanged or no socket exists; the `ui_ping` reply path
    /// (GatewayClient) covers the steady-state polling.
    private func reportForegroundStateIfChanged() {
        let foreground = currentForeground
        guard lastReportedForeground != foreground else { return }
        lastReportedForeground = foreground
        AppLog.debug("📲 ui_state change → foreground=%@ (appActive=%@ unlocked=%@)",
                     foreground ? "true" : "false",
                     appActive ? "true" : "false",
                     deviceUnlocked ? "true" : "false")
        gateway?.sendUIState(foreground: foreground)
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

    /// Human-readable iOS application state, for silent-push diagnostics. Same
    /// isolation/access pattern as `isBackgrounded`.
    private var appStateString: String {
        #if canImport(UIKit)
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
        #else
        return "macos"
        #endif
    }

    /// Post a local notification for a newly-decrypted, push-eligible plugin
    /// message (mirrors the `chat4000.push` flag, protocol E), deduped by event
    /// id and capped per sync batch. Streaming partials (`chat4000.push: false`)
    /// and tool/status events never notify.
    private func maybePostBackgroundNotification(roomId: String, outer: SyncEvent, clear: String?) {
        // Every early return is logged with its reason: when no banner appears,
        // the device log tells us exactly which gate dropped it (silent-push
        // diagnostics).
        guard backgroundNotifyCount < 3 else {
            AppLog.log("🔔 [push] bg-notify SKIP eid=%@ reason=cap count=%ld",
                       outer.eventId ?? "(nil)", backgroundNotifyCount)
            return
        }
        guard let eid = outer.eventId else {
            AppLog.log("🔔 [push] bg-notify SKIP reason=no_event_id room=%@", roomId)
            return
        }
        guard !Self.wasNotified(eid) else {
            AppLog.log("🔔 [push] bg-notify SKIP eid=%@ reason=already_notified", eid)
            return
        }
        // Push eligibility: explicit `chat4000.push: false` on the cleartext
        // envelope → not the final answer → skip.
        if let envelope = parseJSON(outer.rawJSON)?["content"] as? [String: Any],
           (envelope["chat4000.push"] as? Bool) == false {
            AppLog.log("🔔 [push] bg-notify SKIP eid=%@ reason=push_flag_false", eid)
            return
        }
        guard let clear, let obj = parseJSON(clear),
              let content = obj["content"] as? [String: Any] else {
            AppLog.log("🔔 [push] bg-notify SKIP eid=%@ reason=no_cleartext_content", eid)
            return
        }

        let msgtype = content["msgtype"] as? String
        let body: String
        switch msgtype {
        case "m.text", "m.notice", "m.emote":
            let newContent = content["m.new_content"] as? [String: Any]
            body = (newContent?["body"] as? String) ?? (content["body"] as? String) ?? "New message"
        case "m.image": body = "📷 Photo"
        case "m.audio": body = "🎤 Voice message"
        default:
            AppLog.log("🔔 [push] bg-notify SKIP eid=%@ reason=msgtype=%@", eid, msgtype ?? "(nil)")
            return // tool / status / other → no notification
        }

        // Defense-in-depth (Bug 2): tool-activity narration ("📚 skill_view: …",
        // "💻 terminal: …") sometimes leaks from the plugin as push-eligible
        // m.text. The timeline already hides it via this same predicate; gate the
        // notification on it too so a plugin slip can't wake the user. The real
        // fix is plugin-side (these must never be push-eligible) — this is only a
        // client backstop.
        if RoomViewModel.isPureToolTranscript(body) {
            AppLog.log("🔔 [push] bg-notify SKIP eid=%@ reason=tool_transcript", eid)
            return
        }

        // F2 (protocol F.2): the NSE now owns the BACKGROUND banner. It wakes on
        // the gateway's visible alert, fetches + decrypts the same event on-device,
        // and replaces the banner body — so this background-wake path must NOT
        // ALSO post a local notification, or every backgrounded message would
        // double-banner (NSE + this). We keep ALL the eligibility gating + logging
        // above (it's the silent-push diagnostics, and still records `markNotified`
        // so a later cold-launch drain doesn't re-alert), but the actual post is
        // retired on iOS. The foreground path (presentLocalNotification while the
        // app is active, called elsewhere) is unaffected.
        AppLog.log("🔔 [push] bg-notify SKIP-POST eid=%@ room=%@ msgtype=%@ reason=nse_owns_background",
                   eid, roomId, msgtype ?? "(nil)")
        Self.markNotified(eid)
        backgroundNotifyCount += 1
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
    /// Discard the durable room cursor (protocol D.2 cursor-expiry recovery). After
    /// a `sync_reset` for `pos`, the next reconnect must NOT resend the expired
    /// cursor (it only re-triggers `M_UNKNOWN_POS`), so we drop it entirely.
    private static func clearSyncPos(userId: String?) {
        UserDefaults.standard.removeObject(forKey: syncPosKey(userId))
    }

    /// Per-account durably-persisted TO-DEVICE cursor (protocol D.1). A SEPARATE
    /// key from `pos` — the two cursors are independent. The device is the source
    /// of truth: we resend it on reconnect so un-acked Olm-wrapped Megolm keys are
    /// re-delivered rather than deleted before they were saved.
    private static func toDevicePosKey(_ userId: String?) -> String { "chat4000.toDevicePos.\(userId ?? "")" }

    /// Where the TO-DEVICE cursor is stored. Protocol F.2.1b / D ("Two drainers, one
    /// shared to-device cursor"): on iOS the app and its NSE both advance this cursor,
    /// so it MUST live in the **shared App-Group** suite — not app-local — or the two
    /// processes diverge. Falls back to `.standard` on macOS (no App Group, no NSE)
    /// and if the suite can't be opened, preserving pre-F2 single-process behavior.
    /// (The room `pos` stays app-local: the NSE never touches the timeline cursor.)
    private static var toDeviceDefaults: UserDefaults { AppGroup.sharedDefaults ?? .standard }

    private static func saveToDevicePos(_ pos: String, userId: String?) {
        toDeviceDefaults.set(pos, forKey: toDevicePosKey(userId))
    }
    private static func loadToDevicePos(userId: String) -> String? {
        let key = toDevicePosKey(userId)
        let store = toDeviceDefaults
        if let v = store.string(forKey: key) { return v }
        // One-time migration: if the cursor lived in app-local `.standard` (pre-F2)
        // and the shared suite doesn't have it yet, adopt the local value — so moving
        // the cursor to shared storage never re-syncs from scratch (which would drop
        // the device_lists delta — protocol D) or lose the to-device position.
        if store !== UserDefaults.standard, let legacy = UserDefaults.standard.string(forKey: key) {
            store.set(legacy, forKey: key)
            return legacy
        }
        return nil
    }
    /// Discard the durable to-device cursor. Only used when a `sync_reset` EXPLICITLY
    /// names `to_device_pos` — never for a `pos_expired` reset, which leaves the
    /// to-device stream (and its Megolm keys) untouched (protocol D.2).
    private static func clearToDevicePos(userId: String?) {
        toDeviceDefaults.removeObject(forKey: toDevicePosKey(userId))
        // Also clear any stale app-local copy so a later read can't resurrect it.
        if AppGroup.sharedDefaults != nil {
            UserDefaults.standard.removeObject(forKey: toDevicePosKey(userId))
        }
    }

    /// Live-sync heartbeat (protocol F.2.1b / D "Two drainers, one shared to-device
    /// cursor"): the app stamps this in the SHARED store on every sync frame while
    /// its WebSocket is up. The NSE reads it and drains to-device for cold-key
    /// recovery ONLY when it is stale (app suspended) — so the app and the NSE never
    /// advance the shared cursor at the same instant (single-writer). Written to the
    /// shared App-Group suite; on macOS (no App Group, no NSE) it harmlessly lands
    /// in `.standard` and is never read.
    static func liveSyncHeartbeatKey(_ userId: String?) -> String {
        "chat4000.liveSyncHeartbeat.\(userId ?? "")"
    }
    static func stampLiveSyncHeartbeat(userId: String?) {
        (AppGroup.sharedDefaults ?? .standard).set(
            Date().timeIntervalSince1970, forKey: liveSyncHeartbeatKey(userId))
    }

    /// Map a `sync_reset` frame's named cursors (protocol D.1/D.2) to the durable
    /// cursors this device clears. Pure + `nonisolated` so the selective-clearing
    /// rule is unit-testable. The device discards EXACTLY the named cursors and
    /// nothing else: an unknown cursor name is ignored (forward-compatible), and a
    /// `pos_expired` reset (`["pos"]`) clears the room cursor only, leaving
    /// `to_device_pos` intact. Duplicates are collapsed; order is preserved.
    nonisolated static func durableCursorsToClear(named cursors: [String]) -> [String] {
        let known: Set<String> = ["pos", "to_device_pos"]
        var seen: Set<String> = []
        var out: [String] = []
        for cursor in cursors where known.contains(cursor) && seen.insert(cursor).inserted {
            out.append(cursor)
        }
        return out
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
