import Foundation

@MainActor
@Observable
final class RelayClient {
    private(set) var state: ConnectionState = .disconnected

    /// Called when a decrypted inner message arrives from the plugin.
    var onInnerMessage: ((InnerMessage) -> Void)?
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
                DevLog.log("🔌 connect() ignored — already \(String(describing: state))")
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

        self.config = config
        shouldReconnect = true
        retryDelay = 2
        state = .connecting

        guard let groupId = config.groupId, config.isValid else {
            state = .failed("Invalid group key")
            return
        }

        DevLog.log("🔌 Connecting to relay: \(config.relayURL.absoluteString)")

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

    func disconnect() {
        DevLog.log("🔌 Disconnecting from relay")
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
    }

    /// Encrypt and send a text message to the plugin.
    func send(text: String) {
        sendInner(InnerMessage.text(text))
    }

    func sendImage(jpegData: Data, mimeType: String = "image/jpeg") {
        sendInner(InnerMessage.image(dataBase64: jpegData.base64EncodedString(), mimeType: mimeType))
    }

    func sendAudio(audioData: Data, mimeType: String = VoiceNoteConstants.mimeType, durationMs: Int, waveform: [Float]) {
        sendInner(
            InnerMessage.audio(
                dataBase64: audioData.base64EncodedString(),
                mimeType: mimeType,
                durationMs: durationMs,
                waveform: waveform
            )
        )
    }

    func sendStatus(_ status: String) {
        sendInner(InnerMessage.status(status), notifyIfOffline: false)
    }

    // MARK: - Handshake

    private func performHandshake(groupId: String) async {
        guard !Task.isCancelled else { return }

        // Send hello
        let deviceToken = PushNotificationManager.shared.deviceToken
        DevLog.log(
            "📤 [push] preparing hello token_present=%@ token_prefix=%@ release_channel=%@",
            deviceToken == nil ? "false" : "true",
            String((deviceToken ?? "").prefix(12)),
            AppRegistrationIdentity.currentReleaseChannel
        )
        guard let helloJSON = RelayOutgoing.hello(groupId: groupId, deviceToken: deviceToken) else {
            state = .failed("Failed to encode hello")
            return
        }

        do {
            try await webSocketTask?.send(.string(helloJSON))
            DevLog.log("📤 Sent hello (group_id: \(groupId.prefix(16))...)")
        } catch {
            DevLog.log("ERROR: Send hello failed: \(error.localizedDescription)")
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
            case .helloOk(let currentTermsVersion, let versionPolicy):
                DevLog.log("✅ hello_ok — connected to relay")
                onTermsVersionUpdate?(currentTermsVersion)
                VersionPolicyManager.shared.update(with: versionPolicy)
                state = .connected
                retryDelay = 2
                startHeartbeat()
                await listenForMessages()

            case .helloError(let code, let msg):
                DevLog.log("ERROR: hello_error \(code): \(msg)")
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
                    DevLog.log("⏳ device slot still held; retrying with backoff")
                    handleConnectionLoss()
                } else {
                    state = .failed("\(code): \(msg)")
                }

            default:
                state = .failed("Unexpected handshake response")
            }
        } catch {
            DevLog.log("ERROR: Handshake receive failed: \(error.localizedDescription)")
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
            DevLog.log(
                "📤 [push] refreshed hello with device token token_present=%@ token_prefix=%@",
                deviceToken == nil ? "false" : "true",
                String((deviceToken ?? "").prefix(12))
            )
        } catch {
            DevLog.log("⚠️ [push] failed to refresh hello device token: \(error.localizedDescription)")
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
                    DevLog.log("ERROR: Receive failed: \(error.localizedDescription)")
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
            DevLog.log("⚠️ App Attest unsupported on this device")
            return false
        }

        guard let challengeJSON = RelayOutgoing.challenge() else {
            DevLog.log("ERROR: Failed to encode challenge request")
            return false
        }

        do {
            try await webSocketTask?.send(.string(challengeJSON))
            guard let challengeResponse = try await receiveParsedMessage() else { return false }

            guard case .challengeOk(let nonce, _) = challengeResponse else {
                DevLog.log("ERROR: Expected challenge_ok during registration")
                return false
            }

            let attestation = try await AppAttestManager.shared.attest(challengeBase64: nonce)
            guard let registerJSON = RelayOutgoing.register(groupId: groupId, attestation: attestation, challenge: nonce) else {
                DevLog.log("ERROR: Failed to encode register payload")
                return false
            }

            try await webSocketTask?.send(.string(registerJSON))
            guard let registerResponse = try await receiveParsedMessage() else { return false }

            switch registerResponse {
            case .registerOk:
                DevLog.log("✅ register_ok — group registered")
                return true
            case .registerError(let code, let message):
                DevLog.log("ERROR: register_error \(code): \(message)")
                return false
            default:
                DevLog.log("ERROR: Unexpected registration response")
                return false
            }
        } catch {
            DevLog.log("ERROR: Group registration failed: \(error.localizedDescription)")
            return false
        }
    }

    private func handleMessage(_ message: RelayMessage) {
        switch message {
        case .msg(let nonce, let ciphertext, _):
            DevLog.log("📥 relay msg envelope received")
            decryptAndDispatch(nonce: nonce, ciphertext: ciphertext)

        case .pong:
            lastPongTime = .now

        default:
            break
        }
    }

    // MARK: - Decrypt + Inner Message Handling

    private func decryptAndDispatch(nonce: String, ciphertext: String) {
        guard let key = config?.groupKey,
              let plaintext = RelayCrypto.decrypt(nonceBase64: nonce, ciphertextBase64: ciphertext, key: key)
        else {
            DevLog.log("ERROR: Failed to decrypt message")
            return
        }

        guard let inner = try? JSONDecoder().decode(InnerMessage.self, from: plaintext) else {
            DevLog.log("ERROR: Failed to decode inner message")
            return
        }

        DevLog.log(
            "📥 inner decoded type=%@ from_role=%@ from_device=%@ from_bundle=%@",
            inner.t.rawValue,
            inner.from?.role.rawValue ?? "nil",
            inner.from?.deviceId ?? "nil",
            inner.from?.bundleId ?? "nil"
        )

        processInnerMessage(inner)
    }

    private func processInnerMessage(_ inner: InnerMessage) {
        if case .textDelta(let d) = inner.body {
            streamBuffers[inner.id, default: ""] += d.delta
        } else if case .textEnd = inner.body {
            streamBuffers.removeValue(forKey: inner.id)
        }
        onInnerMessage?(inner)
    }

    private func sendInner(_ inner: InnerMessage, notifyIfOffline: Bool = true) {
        guard let envelope = encodedEnvelope(for: inner, notifyIfOffline: notifyIfOffline) else {
            return
        }

        let frameBytes = envelope.lengthOfBytes(using: .utf8)
        guard frameBytes <= RelayProtocol.maxMessageSize else {
            DevLog.log(
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
            DevLog.log("ERROR: No group key for inner send type=%@", inner.t.rawValue)
            return nil
        }

        guard let jsonData = try? JSONEncoder().encode(inner) else {
            DevLog.log("ERROR: Failed to encode inner message type=%@", inner.t.rawValue)
            return nil
        }

        guard let (nonce, ciphertext) = RelayCrypto.encrypt(plaintext: jsonData, key: key) else {
            DevLog.log("ERROR: Encryption failed for inner type=%@", inner.t.rawValue)
            return nil
        }

        guard let envelope = RelayOutgoing.msg(
            nonce: nonce,
            ciphertext: ciphertext,
            msgId: inner.id,
            notifyIfOffline: notifyIfOffline
        ) else {
            DevLog.log("ERROR: Failed to build msg envelope for inner type=%@", inner.t.rawValue)
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
                    DevLog.log("WARN: Pong timeout — reconnecting")
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

        heartbeatTask?.cancel()
        heartbeatTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil

        state = .reconnecting
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60) // exponential backoff, 60s max

        DevLog.log("🔄 Reconnecting in \(Int(delay))s (next: \(Int(retryDelay))s)...")

        connectionTask?.cancel()
        connectionTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, shouldReconnect, let config else { return }
            connect(config: config)
        }
    }
}
