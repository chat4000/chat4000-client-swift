import Foundation

@MainActor
@Observable
final class RelayClient {
    private(set) var state: ConnectionState = .disconnected {
        didSet {
            // Release the App Nap activity token whenever the relay leaves
            // an active state. .reconnecting deliberately keeps the token
            // held so the pending reconnect itself cannot be suspended.
            switch state {
            case .failed, .disconnected:
                AppNapBlocker.shared.end()
            default:
                break
            }
        }
    }

    /// Called when a decrypted inner message arrives from the plugin.
    /// `seq` is the relay-assigned per-recipient sequence number, or nil if
    /// the relay is running a pre-ack build.
    var onInnerMessage: ((InnerMessage, UInt64?) -> Void)?
    /// Called when the relay confirms an outbound message was accepted and
    /// fanned out (per protocol §6.6.4). Drives the "✓ sent" UI tick.
    var onRelayRecvAck: ((String) -> Void)?
    /// Called when the relay reports the current required Terms version.
    var onTermsVersionUpdate: ((Int) -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var config: GroupConfig?
    private var connectionTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var lastPongTime: Date = .now
    private var retryDelay: TimeInterval = 2
    private var shouldReconnect = true
    private var isRegistering = false
    nonisolated(unsafe) private var deviceTokenRefreshTask: Task<Void, Never>?

    /// Per-connection persistence-ack tracker (per protocol §6.6.3). Owned by
    /// the relay client because its emit cadence depends on the WebSocket
    /// being live.
    let ackTracker = AckTracker()

    // Accumulates streamed text deltas keyed by inner message id
    private var streamBuffers: [String: String] = [:]

    // MARK: - Public API

    init() {
        deviceTokenRefreshTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: PushNotificationManager.deviceTokenDidChangeNotification
            ) {
                guard let self else { return }
                await self.refreshHelloDeviceTokenIfNeeded()
            }
        }
    }

    deinit {
        deviceTokenRefreshTask?.cancel()
    }

    func connect(config: GroupConfig) {
        if webSocketTask != nil {
            switch state {
            case .connecting, .connected:
                AppLog.log("🔌 connect() ignored — already \(String(describing: state))")
                self.config = config
                shouldReconnect = true
                return
            default:
                // .failed / .disconnected with a stale task: tear it down
                // before we overwrite the properties, otherwise the URLSession
                // strong reference cycle leaks the old socket + delegate.
                connectionTask?.cancel()
                connectionTask = nil
                heartbeatTask?.cancel()
                heartbeatTask = nil
                webSocketTask?.cancel(with: .goingAway, reason: nil)
                webSocketTask = nil
                session?.invalidateAndCancel()
                session = nil
            }
        }

        // Block macOS App Nap for the lifetime of the relay session. Without
        // this the receive loop gets suspended when the chat window is
        // unfocused, the relay's idle-ping fails, the connection RSTs, and
        // any kernel-buffered frames are silently lost.
        AppNapBlocker.shared.begin()

        self.config = config
        shouldReconnect = true
        retryDelay = 2
        state = .connecting

        guard let groupId = config.groupId, config.isValid else {
            state = .failed("Invalid group key")
            return
        }

        // Wire the ack tracker against this connection. Reset clears any
        // pending seqs left over from a previous session — they would have
        // already been durably checkpointed in AckSeqStore.
        ackTracker.reset()
        ackTracker.groupId = groupId
        ackTracker.send = { [weak self] frame in
            guard let task = self?.webSocketTask else { return }
            Task { try? await task.send(.string(frame)) }
        }

        AppLog.log("🔌 Connecting to relay: \(config.relayURL.absoluteString)")

        let sessionConfig = URLSessionConfiguration.default
        // WebSocket sessions are intentionally long-lived. A short resource
        // timeout causes idle sockets to be torn down every minute on macOS,
        // which creates reconnect gaps where messages can be missed.
        sessionConfig.timeoutIntervalForRequest = 15
        session = URLSession(
            configuration: sessionConfig,
            delegate: RelaySessionDelegate.shared,
            delegateQueue: nil
        )
        webSocketTask = session?.webSocketTask(with: config.relayURL)
        webSocketTask?.maximumMessageSize = 4 * 1024 * 1024
        webSocketTask?.resume()

        connectionTask?.cancel()
        connectionTask = Task { await performHandshake(groupId: groupId) }
    }

    /// The currently-connected group_id, or nil if not configured. Used by
    /// the message persistence layer to scope the ack high-water mark store.
    var currentGroupId: String? { config?.groupId }

    func disconnect() {
        AppLog.log("🔌 Disconnecting from relay")
        // Final ack flush before tearing down the socket so the relay can
        // evict everything we've persisted.
        ackTracker.flushNow()
        shouldReconnect = false
        connectionTask?.cancel()
        connectionTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        state = .disconnected
        AppNapBlocker.shared.end()
    }

    /// Encrypt and send a text message to the plugin. Returns the inner
    /// `id` that the relay will echo on `relay_recv_ack` and that peers will
    /// reference in their inner `ack` `refs` field.
    @discardableResult
    func send(text: String) -> String {
        let inner = InnerMessage.text(text)
        sendInner(inner)
        return inner.id
    }

    @discardableResult
    func sendImage(jpegData: Data, mimeType: String = "image/jpeg") -> String {
        let inner = InnerMessage.image(dataBase64: jpegData.base64EncodedString(), mimeType: mimeType)
        sendInner(inner)
        return inner.id
    }

    @discardableResult
    func sendAudio(audioData: Data, mimeType: String = VoiceNoteConstants.mimeType, durationMs: Int, waveform: [Float]) -> String {
        let inner = InnerMessage.audio(
            dataBase64: audioData.base64EncodedString(),
            mimeType: mimeType,
            durationMs: durationMs,
            waveform: waveform
        )
        sendInner(inner)
        return inner.id
    }

    func sendStatus(_ status: String) {
        sendInner(InnerMessage.status(status), notifyIfOffline: false)
    }

    // MARK: - Handshake

    private func performHandshake(groupId: String) async {
        guard !Task.isCancelled else { return }

        // Send hello
        let deviceToken = PushNotificationManager.shared.deviceToken
        AppLog.log(
            "📤 [push] preparing hello token_present=%@ token_prefix=%@ release_channel=%@",
            deviceToken == nil ? "false" : "true",
            String((deviceToken ?? "").prefix(12)),
            AppRegistrationIdentity.currentReleaseChannel
        )
        let lastAckedSeq = AckSeqStore.lastAckedSeq(forGroupId: groupId)
        guard let helloJSON = RelayOutgoing.hello(
            groupId: groupId,
            deviceToken: deviceToken,
            lastAckedSeq: lastAckedSeq > 0 ? lastAckedSeq : nil
        ) else {
            state = .failed("Failed to encode hello")
            return
        }

        do {
            try await webSocketTask?.send(.string(helloJSON))
            AppLog.log("📤 Sent hello (group_id: \(groupId.prefix(16))...)")
        } catch {
            AppLog.log("ERROR: Send hello failed: \(error.localizedDescription)")
            handleConnectionLoss()
            return
        }

        // Wait for hello_ok or hello_error
        do {
            guard let parsed = try await receiveParsedMessage() else {
                handleConnectionLoss()
                return
            }

            switch parsed {
            case .helloOk(let currentTermsVersion, let versionPolicy, let pluginVersionPolicy):
                AppLog.log("✅ hello_ok — connected to relay")
                onTermsVersionUpdate?(currentTermsVersion)
                VersionPolicyManager.shared.update(with: versionPolicy)
                PluginVersionPolicyManager.shared.updatePolicy(pluginVersionPolicy)
                state = .connected
                retryDelay = 2
                startHeartbeat()
                await listenForMessages()

            case .helloError(let code, let msg):
                AppLog.log("ERROR: hello_error \(code): \(msg)")
                if code == "KEY_NOT_REGISTERED" {
                    let registered = await registerPairIfNeeded(groupId: groupId)
                    if registered {
                        await performHandshake(groupId: groupId)
                    } else if AppAttestManager.shared.isSupported {
                        state = .failed("Group key registration failed.")
                    } else {
                        state = .failed("Group key not registered and App Attest is unavailable on this device.")
                    }
                } else if code == "DEVICE_ALREADY_CONNECTED" {
                    // The relay still has our previous socket's entry in its
                    // dedup map — typically because the prior close hasn't
                    // propagated yet (TCP handoff, force-quit, rapid bg→fg).
                    // Tear down and let exponential backoff retry; the slot
                    // frees within seconds once the relay observes the close.
                    AppLog.log("⏳ device slot still held; retrying with backoff")
                    handleConnectionLoss()
                } else {
                    state = .failed("\(code): \(msg)")
                }

            default:
                state = .failed("Unexpected handshake response")
            }
        } catch {
            AppLog.log("ERROR: Handshake receive failed: \(error.localizedDescription)")
            handleConnectionLoss()
        }
    }

    private func refreshHelloDeviceTokenIfNeeded() async {
        let deviceToken = PushNotificationManager.shared.deviceToken
        guard state == .connected,
              let groupId = config?.groupId,
              let helloJSON = RelayOutgoing.hello(
                  groupId: groupId,
                  deviceToken: deviceToken
              )
        else { return }

        do {
            try await webSocketTask?.send(.string(helloJSON))
            AppLog.log(
                "📤 [push] refreshed hello with device token token_present=%@ token_prefix=%@",
                deviceToken == nil ? "false" : "true",
                String((deviceToken ?? "").prefix(12))
            )
        } catch {
            AppLog.log("⚠️ [push] failed to refresh hello device token: \(error.localizedDescription)")
        }
    }

    // MARK: - Message Loop

    private func listenForMessages() async {
        guard let task = webSocketTask else { return }

        while !Task.isCancelled, state == .connected {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    if let parsed = RelayMessage.parse(from: text) {
                        handleMessage(parsed)
                    }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8),
                       let parsed = RelayMessage.parse(from: text) {
                        handleMessage(parsed)
                    }
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled, state == .connected {
                    AppLog.log("ERROR: Receive failed: \(error.localizedDescription)")
                    handleConnectionLoss()
                }
                return
            }
        }
    }

    private func receiveParsedMessage() async throws -> RelayMessage? {
        guard let message = try await webSocketTask?.receive() else {
            return nil
        }

        switch message {
        case .string(let text):
            return RelayMessage.parse(from: text)
        case .data(let data):
            return RelayMessage.parse(from: data)
        @unknown default:
            return nil
        }
    }

    private func registerPairIfNeeded(groupId: String) async -> Bool {
        guard !isRegistering else { return false }
        isRegistering = true
        defer { isRegistering = false }

        guard AppAttestManager.shared.isSupported else {
            AppLog.log("⚠️ App Attest unsupported on this device")
            return false
        }

        guard let challengeJSON = RelayOutgoing.challenge() else {
            AppLog.log("ERROR: Failed to encode challenge request")
            return false
        }

        do {
            try await webSocketTask?.send(.string(challengeJSON))
            guard let challengeResponse = try await receiveParsedMessage() else { return false }

            guard case .challengeOk(let nonce, _) = challengeResponse else {
                AppLog.log("ERROR: Expected challenge_ok during registration")
                return false
            }

            let attestation = try await AppAttestManager.shared.attest(challengeBase64: nonce)
            guard let registerJSON = RelayOutgoing.register(groupId: groupId, attestation: attestation, challenge: nonce) else {
                AppLog.log("ERROR: Failed to encode register payload")
                return false
            }

            try await webSocketTask?.send(.string(registerJSON))
            guard let registerResponse = try await receiveParsedMessage() else { return false }

            switch registerResponse {
            case .registerOk:
                AppLog.log("✅ register_ok — group registered")
                return true
            case .registerError(let code, let message):
                AppLog.log("ERROR: register_error \(code): \(message)")
                return false
            default:
                AppLog.log("ERROR: Unexpected registration response")
                return false
            }
        } catch {
            AppLog.log("ERROR: Group registration failed: \(error.localizedDescription)")
            return false
        }
    }

    private func handleMessage(_ message: RelayMessage) {
        switch message {
        case .msg(let nonce, let ciphertext, _, let seq):
            if let seq {
                AppLog.log("📥 relay msg envelope received seq=%llu", seq)
            } else {
                AppLog.log("📥 relay msg envelope received (no seq, pre-ack relay)")
            }
            decryptAndDispatch(nonce: nonce, ciphertext: ciphertext, seq: seq)

        case .relayRecvAck(let msgId, let queuedFor):
            AppLog.log(
                "✅ relay_recv_ack msg_id=%@ queued_for=%@",
                msgId,
                (queuedFor ?? []).joined(separator: ",")
            )
            onRelayRecvAck?(msgId)

        case .pong:
            lastPongTime = .now

        default:
            break
        }
    }

    // MARK: - Decrypt + Inner Message Handling

    private func decryptAndDispatch(nonce: String, ciphertext: String, seq: UInt64?) {
        guard let key = config?.groupKey,
              let plaintext = RelayCrypto.decrypt(nonceBase64: nonce, ciphertextBase64: ciphertext, key: key)
        else {
            AppLog.log("ERROR: Failed to decrypt message")
            return
        }

        guard let inner = try? JSONDecoder().decode(InnerMessage.self, from: plaintext) else {
            AppLog.log("ERROR: Failed to decode inner message")
            return
        }

        AppLog.log(
            "📥 inner decoded type=%@ from_role=%@ from_device=%@ from_bundle=%@",
            inner.t.rawValue,
            inner.from?.role.rawValue ?? "nil",
            inner.from?.deviceId ?? "nil",
            inner.from?.bundleId ?? "nil"
        )

        // Per protocol §6.3 plugin version policy: observe the plugin's actual
        // running version from inner messages where `from.role == "plugin"`.
        if let from = inner.from, from.role == .plugin {
            PluginVersionPolicyManager.shared.observePlugin(
                version: from.appVersion,
                bundleId: from.bundleId
            )
        }

        processInnerMessage(inner, seq: seq)
    }

    private func processInnerMessage(_ inner: InnerMessage, seq: UInt64?) {
        if case .textDelta(let d) = inner.body {
            streamBuffers[inner.id, default: ""] += d.delta
        } else if case .textEnd = inner.body {
            streamBuffers.removeValue(forKey: inner.id)
        }
        onInnerMessage?(inner, seq)
    }

    private func sendInner(_ inner: InnerMessage, notifyIfOffline: Bool = true) {
        guard let envelope = encodedEnvelope(for: inner, notifyIfOffline: notifyIfOffline) else {
            return
        }

        let frameBytes = envelope.lengthOfBytes(using: .utf8)
        guard frameBytes <= RelayProtocol.maxMessageSize else {
            AppLog.log(
                "ERROR: Outgoing inner type=%@ exceeds relay max frame size bytes=%ld max=%ld",
                inner.t.rawValue,
                frameBytes,
                RelayProtocol.maxMessageSize
            )
            return
        }

        let task = webSocketTask
        Task { try? await task?.send(.string(envelope)) }
    }

    private func encodedEnvelope(for inner: InnerMessage, notifyIfOffline: Bool) -> String? {
        guard let key = config?.groupKey else {
            AppLog.log("ERROR: No group key for inner send type=%@", inner.t.rawValue)
            return nil
        }

        guard let jsonData = try? JSONEncoder().encode(inner) else {
            AppLog.log("ERROR: Failed to encode inner message type=%@", inner.t.rawValue)
            return nil
        }

        guard let (nonce, ciphertext) = RelayCrypto.encrypt(plaintext: jsonData, key: key) else {
            AppLog.log("ERROR: Encryption failed for inner type=%@", inner.t.rawValue)
            return nil
        }

        guard let envelope = RelayOutgoing.msg(
            nonce: nonce,
            ciphertext: ciphertext,
            msgId: inner.id,
            notifyIfOffline: notifyIfOffline
        ) else {
            AppLog.log("ERROR: Failed to build msg envelope for inner type=%@", inner.t.rawValue)
            return nil
        }
        return envelope
    }

    // MARK: - Heartbeat (ping/pong)

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        lastPongTime = .now

        heartbeatTask = Task { [weak self] in
            let interval = RelayProtocol.heartbeatIntervalSecs

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }

                // Check pong timeout (2x interval = 60s without pong)
                if Date.now.timeIntervalSince(self.lastPongTime) > interval * 2 {
                    AppLog.log("WARN: Pong timeout — reconnecting")
                    self.handleConnectionLoss()
                    return
                }

                // Send ping
                if let json = RelayOutgoing.ping() {
                    try? await self.webSocketTask?.send(.string(json))
                }
            }
        }
    }

    // MARK: - Reconnect

    private func handleConnectionLoss() {
        guard shouldReconnect else { return }

        // Best-effort flush before the socket is torn down. The actual send
        // call may not land if the socket is already half-closed, but the
        // tracker still updates AckSeqStore so the next hello carries the
        // latest high-water mark and the relay redrives correctly.
        ackTracker.flushNow()

        heartbeatTask?.cancel()
        heartbeatTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil

        state = .reconnecting
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60) // exponential backoff, 60s max

        AppLog.log("🔄 Reconnecting in \(Int(delay))s (next: \(Int(retryDelay))s)...")

        connectionTask?.cancel()
        connectionTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, shouldReconnect, let config else { return }
            connect(config: config)
        }
    }
}
