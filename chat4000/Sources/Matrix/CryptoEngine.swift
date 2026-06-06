import Foundation
import MatrixSDKCrypto

// ─────────────────────────────────────────────────────────────────────────────
// Own the standalone Olm/Megolm machine and translate its crypto
// protocol into homeserver C-S calls sent over the gateway. We do NOT implement
// crypto — `OlmMachine` (the audited matrix-sdk-crypto FFI) does; this drives it:
//   • feed sync to-device/key-state in, drain its outgoing requests out
//     (keysUpload/keysQuery/keysClaim/toDevice/signatureUpload/keysBackup/
//      roomMessage) as gateway `req`s, then ack each via `markRequestAsSent`;
//   • encrypt a room event (megolm) after ensuring sessions + sharing the room
//     key, and PUT it as `m.room.encrypted` (protocol D.2);
//   • decrypt an inbound `m.room.encrypted` event to cleartext.
// ─────────────────────────────────────────────────────────────────────────────

/// The narrow homeserver-call seam CryptoEngine needs. `GatewayClient` already
/// exposes exactly this method, so on B3 it conforms with a one-line extension.
/// Keeping CryptoEngine behind a protocol (not the concrete client) keeps it
/// unit-testable with a mock transport.
@MainActor
protocol GatewayRequesting: AnyObject {
    @discardableResult
    func request(method: String, path: String, body: [String: Any]?) async throws(AppError) -> (status: Int, body: Data)
}

@MainActor
final class CryptoEngine {
    private let machine: OlmMachine
    private let gateway: GatewayRequesting

    /// v1-equivalent posture: decrypt regardless of device trust. Hardening to
    /// cross-signing-required is a later step (we auto-enable cross-signing on
    /// the account, but gating decryption on it now would drop legitimate
    /// messages before verification flows exist).
    private let decryptionSettings = DecryptionSettings(senderDeviceTrustRequirement: .untrusted)

    /// Bound so a misbehaving machine that keeps regenerating requests can't spin
    /// forever; one or two passes is the normal case.
    private let maxPumpPasses = 20

    /// Set once, globally: pipe matrix-sdk-crypto's internal Rust tracing into
    /// AppLog so Olm session create/replace, prekey handling, and decrypt
    /// failures are visible (the detail needed to diagnose an Olm session
    /// race/wedge). `setLogger` is a module-global, so guard against re-install
    /// on reconnect (which constructs a fresh CryptoEngine).
    private static var tracingInstalled = false

    init(userId: String, deviceId: String, storePath: String, gateway: GatewayRequesting) throws(AppError) {
        // Install crypto tracing BEFORE the machine so its init is captured too.
        if !Self.tracingInstalled {
            setLogger(logger: CryptoTracingLogger())
            Self.tracingInstalled = true
        }
        // passphrase: nil → the crypto (Olm/Megolm key) store is NOT encrypted
        // at rest. Deliberate: it sits inside the app sandbox under iOS file
        // protection, and an unencrypted store sidesteps the passphrase-mismatch
        // failure mode (CryptoStoreError.OpenStore). Messages live in SwiftData,
        // not here — this store is keys only.
        do {
            self.machine = try OlmMachine(userId: userId, deviceId: deviceId, path: storePath, passphrase: nil)
        } catch is CancellationError {
            throw AppError.cancelled
        } catch {
            ErrorReporter.capture(error, context: "CryptoEngine.init.OlmMachine")
            throw AppError.unexpected(error)
        }
        self.gateway = gateway
    }

    // MARK: - Sync intake

    /// Feed one sync's e2ee state into the machine, then drain its outgoing
    /// requests. Call this BEFORE processing the sync's room events so freshly
    /// received room keys are available for decryption.
    func processSync(_ sync: GatewaySync) async throws(AppError) {
        AppLog.debug("🔐 processSync to_device=%d changed=%d left=%d otk=%@ fallback=%@",
                     sync.toDevice.count, sync.deviceLists.changed.count, sync.deviceLists.left.count,
                     sync.oneTimeKeyCounts.description, sync.unusedFallbackKeyTypes?.description ?? "nil")
        // DIAG (Olm intake): log every RAW inbound to-device event (type, sender,
        // sender_key, algorithm) so we can see exactly what the plugin sent —
        // including its m.olm key-share — before the machine consumes it.
        // swiftlint:disable:next empty_count - `count` is a wire field (event count), not collection emptiness.
        if sync.toDevice.count > 0 { logToDeviceBatch("⬇️ raw", sync.toDevice.eventsJSON) }

        let deviceChanges = DeviceLists(changed: sync.deviceLists.changed, left: sync.deviceLists.left)
        let result: SyncChangesResult
        do {
            result = try machine.receiveSyncChanges(
                events: sync.toDevice.eventsJSON,
                deviceChanges: deviceChanges,
                keyCounts: sync.oneTimeKeyCounts,
                unusedFallbackKeys: sync.unusedFallbackKeyTypes,
                nextBatchToken: sync.pos ?? "",
                decryptionSettings: decryptionSettings
            )
        } catch {
            // The machine REJECTED the whole batch (a thrown error, not a silent
            // UTD) — e.g. "invalid type: map, expected a sequence". When this
            // happens the plugin's m.room_key in this batch is never imported.
            // Kept at INFO as a hard error signal; the raw bytes (which contain
            // ciphertext) go to DEBUG only.
            AppLog.log("🔑 ⛔ receiveSyncChanges threw on a %d-event batch: %@", sync.toDevice.count, String(describing: error))
            AppLog.debug("🔑 ⛔ events_json_prefix=%@", String(sync.toDevice.eventsJSON.prefix(280)))
            if error is CancellationError { throw AppError.cancelled }
            // The machine rejected the whole batch — a classifiable crypto failure.
            throw AppError.crypto("receiveSyncChanges: \(error.localizedDescription)")
        }

        // What did the machine DECRYPT out of that batch? An m.room_key here means
        // the key landed. (key-revealing → DEBUG)
        if !result.toDeviceEvents.isEmpty {
            AppLog.debug("🔑 receiveSyncChanges decrypted %d to-device event(s):", result.toDeviceEvents.count)
            for ev in result.toDeviceEvents { logToDeviceEvent("✅ decrypted", ev) }
            // swiftlint:disable:next empty_count - `count` is a wire field (event count), not collection emptiness.
        } else if sync.toDevice.count > 0 {
            // Non-revealing signal that a batch yielded nothing — keep at INFO.
            AppLog.log("🔑 ⚠️ batch of %d to-device produced 0 decrypted events", sync.toDevice.count)
        }
        try await runOutgoingRequests()
    }

    // MARK: - Outgoing-request pump

    /// Drain `machine.outgoingRequests()` to the homeserver until empty (acking
    /// each), bounded by `maxPumpPasses`. `markRequestAsSent` can enqueue new
    /// requests (e.g. a key query surfacing identity changes), hence the loop.
    func runOutgoingRequests() async throws(AppError) {
        for pass in 0..<maxPumpPasses {
            let requests: [Request]
            do {
                requests = try machine.outgoingRequests()
            } catch is CancellationError {
                throw AppError.cancelled
            } catch {
                ErrorReporter.capture(error, context: "CryptoEngine.outgoingRequests")
                throw AppError.unexpected(error)
            }
            AppLog.debug("🔐 pump pass %d: %d outgoing request(s)", pass, requests.count)
            if requests.isEmpty { return }
            for request in requests {
                try await send(request)
            }
            if pass == maxPumpPasses - 1 {
                AppLog.log("⚙️ CryptoEngine pump hit cap (%d) — outgoing requests may remain", maxPumpPasses)
            }
        }
    }

    /// Ack a drained request to the machine. `machine.markRequestAsSent` is the
    /// FFI boundary, wrapped so only `AppError` escapes.
    private func markSent(_ requestId: String, _ type: RequestType, _ responseBody: String) throws(AppError) {
        do {
            try machine.markRequestAsSent(requestId: requestId, requestType: type, responseBody: responseBody)
        } catch is CancellationError {
            throw AppError.cancelled
        } catch {
            ErrorReporter.capture(error, context: "CryptoEngine.markRequestAsSent")
            throw AppError.unexpected(error)
        }
    }

    private func send(_ request: Request) async throws(AppError) {
        AppLog.debug("🔐→ outgoing %@", Self.describe(request))
        switch request {
        case let .keysUpload(requestId, body):
            let resp = try await post("/_matrix/client/v3/keys/upload", jsonBody: body)
            try markSent(requestId, .keysUpload, resp)
            // DIAG (D): how many one-time keys does the server hold for us now?
            // If this drops to 0, the plugin may claim an OTK we've discarded →
            // its prekey Olm message becomes undecryptable.
            let otkCounts = (try? dict(fromJSON: resp))?["one_time_key_counts"]
            AppLog.debug("🔑 keysUpload ok server_otk_counts=%@", String(describing: otkCounts ?? "-"))

        case let .keysQuery(requestId, users):
            // The FFI hands us the user list; the C-S body is `{device_keys:{u:[]}}`.
            var deviceKeys: [String: Any] = [:]
            for user in users { deviceKeys[user] = [String]() }
            let resp = try await post("/_matrix/client/v3/keys/query", dictBody: ["device_keys": deviceKeys])
            try markSent(requestId, .keysQuery, resp)
            // DIAG (C): which devices + curve25519 keys did we learn for each
            // queried user? Confirms we actually see the plugin's device (and the
            // curve25519 it shares room keys from).
            AppLog.debug("🔑 keysQuery users=[%@] → %@", users.joined(separator: ","), summarizeDeviceKeys(resp))

        case let .keysClaim(requestId, oneTimeKeys):
            // DIAG (C): which user/device/algorithm are we claiming an OTK for?
            AppLog.debug("🔑 keysClaim targets=\(oneTimeKeys)")
            let resp = try await post("/_matrix/client/v3/keys/claim", dictBody: ["one_time_keys": oneTimeKeys])
            try markSent(requestId, .keysClaim, resp)
            // DIAG (C): did the homeserver actually hand back the plugin's OTK
            // (so we can establish the Olm session), or did it `failures` out?
            AppLog.debug("🔑 keysClaim result %@", summarizeKeysClaim(resp))

        case let .toDevice(requestId, eventType, body):
            // The FFI `body` is the messages map ({user:{device:content}}); the
            // C-S sendToDevice endpoint wants it wrapped under `messages`.
            // Without the wrapper the homeserver 400s (M_BAD_JSON: missing field
            // `messages`) and room-key sharing — hence all encrypted sends —
            // fails. requestId doubles as the idempotent txn id.
            let messages = (try? dict(fromJSON: body)) ?? [:]
            let path = "/_matrix/client/v3/sendToDevice/\(encode(eventType))/\(encode(requestId))"
            let resp = try await put(path, dictBody: ["messages": messages])
            try markSent(requestId, .toDevice, resp)

        case let .signatureUpload(requestId, body):
            let resp = try await post("/_matrix/client/v3/keys/signatures/upload", jsonBody: body)
            try markSent(requestId, .signatureUpload, resp)

        case let .keysBackup(requestId, version, rooms):
            // FFI `rooms` is the rooms map; the C-S body wraps it under `rooms`.
            let roomsMap = (try? dict(fromJSON: rooms)) ?? [:]
            let path = "/_matrix/client/v3/room_keys/keys?version=\(encode(version))"
            let resp = try await put(path, dictBody: ["rooms": roomsMap])
            try markSent(requestId, .keysBackup, resp)

        case let .roomMessage(requestId, roomId, eventType, content):
            let path = "/_matrix/client/v3/rooms/\(encode(roomId))/send/\(encode(eventType))/\(encode(requestId))"
            let resp = try await put(path, jsonBody: content)
            try markSent(requestId, .roomMessage, resp)
        }
    }

    // MARK: - Room key / encryption lifecycle

    /// Tell the machine a room is megolm-encrypted (from `m.room.encryption` in
    /// sync). Required before `encrypt`/`shareRoomKey` for that room.
    func markRoomEncrypted(_ roomId: String) throws(AppError) {
        do {
            try machine.setRoomAlgorithm(roomId: roomId, algorithm: .megolmV1AesSha2)
        } catch is CancellationError {
            throw AppError.cancelled
        } catch {
            ErrorReporter.capture(error, context: "CryptoEngine.markRoomEncrypted")
            throw AppError.unexpected(error)
        }
    }

    /// Keep the machine's tracked-user set in step with room membership so it
    /// queries/claims keys for the right devices.
    func updateTrackedUsers(_ users: [String]) throws(AppError) {
        do {
            try machine.updateTrackedUsers(users: users)
        } catch is CancellationError {
            throw AppError.cancelled
        } catch {
            ErrorReporter.capture(error, context: "CryptoEngine.updateTrackedUsers")
            throw AppError.unexpected(error)
        }
    }

    /// Encrypt `content` for `roomId` and send it as `m.room.encrypted`
    /// (protocol D.2). `cleartextEnvelope` carries the fields that ride OUTSIDE
    /// the ciphertext on the event (protocol E): `chat4000.push` and, for turn
    /// events, `m.relates_to`. Ensures olm sessions + shares the room key first.
    /// Returns the homeserver `event_id`.
    @discardableResult
    func encryptAndSend(
        roomId: String,
        recipients: [String],
        eventType: String = "m.room.message",
        content: [String: Any],
        cleartextEnvelope: [String: Any] = [:]
    ) async throws(AppError) -> String? {
        AppLog.debug("🔐 encryptAndSend room=%@ type=%@ recipients=%d", roomId, eventType, recipients.count)
        if let claim = try getMissingSessions(recipients) {
            AppLog.debug("🔐 getMissingSessions → claiming")
            try await send(claim)
            try await runOutgoingRequests()
        }

        let shareRequests = try shareRoomKey(roomId: roomId, recipients: recipients)
        AppLog.debug("🔐 shareRoomKey → %d to-device request(s)", shareRequests.count)
        for request in shareRequests { try await send(request) }

        let plaintext = try jsonString(content)
        let encrypted = try encryptEvent(roomId: roomId, eventType: eventType, plaintext: plaintext)

        // `encrypt` returns the `m.room.encrypted` content (algorithm,
        // ciphertext, sender_key, …). Splice the cleartext envelope fields onto
        // that object so the homeserver can read `chat4000.push` / aggregate
        // `m.relates_to` without seeing plaintext.
        var outer = (try? dict(fromJSON: encrypted)) ?? [:]
        for (key, value) in cleartextEnvelope { outer[key] = value }

        let txnId = UUID().uuidString
        let path = "/_matrix/client/v3/rooms/\(encode(roomId))/send/m.room.encrypted/\(encode(txnId))"
        let resp = try await put(path, dictBody: outer)
        let eventId = (try? dict(fromJSON: resp))?["event_id"] as? String
        AppLog.debug("🔐 sent encrypted to %@ → event_id=%@", roomId, eventId ?? "nil")
        return eventId
    }

    /// Read-only readiness probe — does NOT query the network, claim, share, or
    /// send. Returns true when every non-self recipient has at least one KNOWN
    /// device (its device list has been fetched). That is the exact condition the
    /// new-session bug needed: when devices ARE known, the next encrypted send
    /// claims one-time keys, establishes the Olm session, and shares the room key
    /// to those devices (>0). We deliberately do NOT also require an existing Olm
    /// session — that only gets built BY a send, so gating on it would deadlock
    /// (button hidden → never sends → never keyed). Used to gate UI readiness/
    /// visibility (I2); the send path is unchanged. Fail-closed: any error, or a
    /// peer whose devices aren't known yet, → not ready.
    func isRoomReachable(recipients: [String], selfUserId: String) -> Bool {
        let peers = recipients.filter { $0 != selfUserId }
        guard !peers.isEmpty else { return false }
        do {
            for user in peers where try machine.getUserDevices(userId: user, timeout: 0).isEmpty {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    /// Decrypt an inbound `m.room.encrypted` event (the full event JSON) to its
    /// cleartext event JSON. Throws if the session is missing/undecryptable —
    /// callers should tolerate that (the key may arrive on a later sync).
    func decrypt(eventJSON: String, roomId: String) throws(AppError) -> String {
        do {
            let result = try machine.decryptRoomEvent(
                event: eventJSON,
                roomId: roomId,
                handleVerificationEvents: false,
                strictShields: false,
                decryptionSettings: decryptionSettings
            )
            return result.clearEvent
        } catch is CancellationError {
            throw AppError.cancelled
        } catch {
            // A missing/undecryptable session is an EXPECTED outcome here (the key
            // may arrive on a later sync); callers tolerate it via `try?`. Map to a
            // classifiable crypto failure rather than reporting it as unexpected.
            throw AppError.crypto("decrypt: \(error.localizedDescription)")
        }
    }

    /// Gossip-request the Megolm key for an event we couldn't decrypt
    /// (`m.room_key_request`). Other devices in the room — including the plugin —
    /// may respond with the key, after which a later re-decrypt succeeds. Sends
    /// the cancellation (if any) + the request as to-device messages.
    func requestRoomKey(forEvent eventJSON: String, roomId: String) async throws(AppError) {
        let pair: KeyRequestPair
        do {
            pair = try machine.requestRoomKey(event: eventJSON, roomId: roomId)
        } catch is CancellationError {
            throw AppError.cancelled
        } catch {
            ErrorReporter.capture(error, context: "CryptoEngine.requestRoomKey")
            throw AppError.unexpected(error)
        }
        if let cancellation = pair.cancellation { try await send(cancellation) }
        try await send(pair.keyRequest)
        // DIAG (E): log the megolm session + sender_key we're asking for so the
        // plugin can confirm the request targets its device/session.
        var session = "-", senderKey = "-"
        if let content = parseContent(eventJSON) {
            session = content["session_id"] as? String ?? "-"
            senderKey = content["sender_key"] as? String ?? "-"
        }
        AppLog.debug("🔐 requested room key room=%@ session=%@ sender_key=%@", roomId, session, senderKey)
    }

    // MARK: - FFI adapters (typed-throws boundary)

    /// `machine.getMissingSessions` wrapped so only `AppError` escapes.
    private func getMissingSessions(_ recipients: [String]) throws(AppError) -> Request? {
        do {
            return try machine.getMissingSessions(users: recipients)
        } catch is CancellationError {
            throw AppError.cancelled
        } catch {
            ErrorReporter.capture(error, context: "CryptoEngine.getMissingSessions")
            throw AppError.unexpected(error)
        }
    }

    /// `machine.shareRoomKey` wrapped so only `AppError` escapes.
    private func shareRoomKey(roomId: String, recipients: [String]) throws(AppError) -> [Request] {
        do {
            return try machine.shareRoomKey(roomId: roomId, users: recipients, settings: encryptionSettings)
        } catch is CancellationError {
            throw AppError.cancelled
        } catch {
            ErrorReporter.capture(error, context: "CryptoEngine.shareRoomKey")
            throw AppError.unexpected(error)
        }
    }

    /// `machine.encrypt` wrapped so only `AppError` escapes.
    private func encryptEvent(roomId: String, eventType: String, plaintext: String) throws(AppError) -> String {
        do {
            return try machine.encrypt(roomId: roomId, eventType: eventType, content: plaintext)
        } catch is CancellationError {
            throw AppError.cancelled
        } catch {
            ErrorReporter.capture(error, context: "CryptoEngine.encrypt")
            throw AppError.unexpected(error)
        }
    }

    // MARK: - Settings

    private var encryptionSettings: EncryptionSettings {
        EncryptionSettings(
            algorithm: .megolmV1AesSha2,
            rotationPeriod: 604_800,        // 1 week (matrix default)
            rotationPeriodMsgs: 100,        // matrix default
            historyVisibility: .shared,
            onlyAllowTrustedDevices: false, // mirrors decryptionSettings posture
            errorOnVerifiedUserProblem: false
        )
    }

    // MARK: - C-S transport helpers

    /// POST/PUT a request whose body the FFI already handed us as a JSON object
    /// string. Returns the response body as a string for `markRequestAsSent`.
    private func post(_ path: String, jsonBody: String) async throws(AppError) -> String {
        try await call("POST", path, body: try? dict(fromJSON: jsonBody))
    }

    private func put(_ path: String, jsonBody: String) async throws(AppError) -> String {
        try await call("PUT", path, body: try? dict(fromJSON: jsonBody))
    }

    private func post(_ path: String, dictBody: [String: Any]) async throws(AppError) -> String {
        try await call("POST", path, body: dictBody)
    }

    private func put(_ path: String, dictBody: [String: Any]) async throws(AppError) -> String {
        try await call("PUT", path, body: dictBody)
    }

    private func call(_ method: String, _ path: String, body: [String: Any]?) async throws(AppError) -> String {
        let (status, data) = try await gateway.request(method: method, path: path, body: body)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        guard (200..<300).contains(status) else {
            // A non-2xx C-S response is an expected, classifiable failure. The
            // status code carries the diagnostic; the body text is logged here.
            AppLog.debug("🔐 C-S %@ %@ failed (%d): %@", method, path, status, String(text.prefix(200)))
            throw AppError.httpStatus(status)
        }
        return text
    }

    // MARK: - JSON helpers

    private func dict(fromJSON json: String) throws(AppError) -> [String: Any] {
        guard let data = json.data(using: .utf8) else {
            throw AppError.decode("crypto JSON not UTF-8")
        }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data)
        } catch is CancellationError {
            throw AppError.cancelled
        } catch {
            // Malformed wire/FFI JSON is an expected, classifiable decode failure.
            throw AppError.decode("crypto JSON parse failed: \(error.localizedDescription)")
        }
        guard let dict = obj as? [String: Any] else {
            throw AppError.decode("crypto JSON was not an object")
        }
        return dict
    }

    private func jsonString(_ obj: [String: Any]) throws(AppError) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let string = String(data: data, encoding: .utf8)
        else { throw AppError.encode("crypto JSON serialization failed") }
        return string
    }

    /// Human-readable request kind for debug logging (no secret material).
    private static func describe(_ request: Request) -> String {
        switch request {
        case .keysUpload: return "keysUpload"
        case let .keysQuery(_, users): return "keysQuery(\(users.count) users)"
        case .keysClaim: return "keysClaim"
        case let .toDevice(_, eventType, _): return "toDevice(\(eventType))"
        case .signatureUpload: return "signatureUpload"
        case .keysBackup: return "keysBackup"
        case let .roomMessage(_, roomId, eventType, _): return "roomMessage(\(eventType) -> \(roomId))"
        }
    }

    /// Percent-encode a single path segment (room ids contain `!`, `:`, `@`).
    private func encode(_ segment: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    // MARK: - Key-exchange diagnostics

    /// One-line summary of a `/keys/query` response: each user's devices and the
    /// curve25519 key the machine now knows for them.
    private func summarizeDeviceKeys(_ resp: String) -> String {
        guard let obj = try? dict(fromJSON: resp),
              let deviceKeys = obj["device_keys"] as? [String: Any] else { return "no device_keys" }
        var parts: [String] = []
        for (_, devices) in deviceKeys {
            guard let devices = devices as? [String: Any] else { continue }
            for (deviceId, dk) in devices {
                let keys = (dk as? [String: Any])?["keys"] as? [String: Any] ?? [:]
                let curve = keys.first { $0.key.hasPrefix("curve25519:") }?.value as? String ?? "?"
                parts.append("\(deviceId)(\(curve))")
            }
        }
        return parts.isEmpty ? "0 devices" : parts.joined(separator: ",")
    }

    /// One-line summary of a `/keys/claim` response: which devices yielded an OTK
    /// (so an Olm session can be built) and which users hard-failed.
    private func summarizeKeysClaim(_ resp: String) -> String {
        guard let obj = try? dict(fromJSON: resp) else { return "unparseable" }
        var claimed: [String] = []
        if let otk = obj["one_time_keys"] as? [String: Any] {
            for (_, devices) in otk {
                if let devices = devices as? [String: Any] { claimed.append(contentsOf: devices.keys) }
            }
        }
        let failures = (obj["failures"] as? [String: Any])?.keys.sorted().joined(separator: ",")
        let failureText = (failures?.isEmpty == false) ? (failures ?? "none") : "none"
        return "claimed=[\(claimed.joined(separator: ","))] failures=\(failureText)"
    }

    // MARK: - To-device diagnostics

    /// Parse a single event JSON and return its `content` object.
    private func parseContent(_ eventJSON: String) -> [String: Any]? {
        guard let data = eventJSON.data(using: .utf8),
              let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return ev["content"] as? [String: Any]
    }

    /// Log each event in a to-device batch. `eventsJSON` is a ruma `ToDevice`
    /// object `{"events":[...]}` (see ToDeviceBatch); tolerate a bare array too.
    private func logToDeviceBatch(_ tag: String, _ eventsJSON: String) {
        guard let data = eventsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        let arr = (obj as? [String: Any])?["events"] as? [[String: Any]]
            ?? obj as? [[String: Any]] ?? []
        for ev in arr { logToDeviceFields(tag, ev) }
    }

    /// Log a single to-device event (JSON object string).
    private func logToDeviceEvent(_ tag: String, _ eventJSON: String) {
        guard let data = eventJSON.data(using: .utf8),
              let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        logToDeviceFields(tag, ev)
    }

    /// Common field dump: type/sender plus the crypto-relevant content fields.
    /// `alg`/`sender_key` identify an inbound m.olm key-share; `room`/`session`
    /// identify a decrypted m.room_key.
    private func logToDeviceFields(_ tag: String, _ ev: [String: Any]) {
        let type = ev["type"] as? String ?? "?"
        let sender = ev["sender"] as? String ?? "?"
        let content = ev["content"] as? [String: Any]
        // key-revealing (sender_key / session_id) → DEBUG (verbose/dev only).
        AppLog.debug("🔑 %@ type=%@ sender=%@ alg=%@ sender_key=%@ room=%@ session=%@",
                   tag, type, sender,
                   content?["algorithm"] as? String ?? "-",
                   content?["sender_key"] as? String ?? "-",
                   content?["room_id"] as? String ?? "-",
                   content?["session_id"] as? String ?? "-")
    }
}

/// Pipes matrix-sdk-crypto's internal Rust tracing into AppLog. Filtered to
/// Olm/Megolm/session/key/decrypt lines so the high-volume trace can't evict
/// our own log lines from the rotating file — exactly the events needed to
/// diagnose an Olm session race/wedge (prekey handling, session create/replace,
/// decrypt failures). Installed once via `CryptoEngine`'s `setLogger`.
private final class CryptoTracingLogger: Logger {
    func log(logLine: String) {
        let l = logLine.lowercased()
        guard l.contains("olm") || l.contains("megolm") || l.contains("session")
            || l.contains("room_key") || l.contains("room key") || l.contains("decrypt")
            || l.contains("prekey") || l.contains("pre-key") || l.contains("one-time")
            || l.contains("wedg") || l.contains("withheld")
        else { return }
        AppLog.debug("🦀 %@", logLine)
    }
}
