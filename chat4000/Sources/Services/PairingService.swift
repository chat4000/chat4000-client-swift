import CryptoKit
import Foundation

@MainActor
@Observable
final class PairingCoordinator {
    enum Flow: String {
        case join = "join"
        case hostedAddDevice = "hosted_add_device"
    }

    enum Phase: Equatable {
        case idle
        case opening
        case waitingForPeer
        case waitingForInitiator
        case verifying
        case transferring
        case complete(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var displayedCode: String?
    private(set) var completedConfig: GroupConfig?
    private(set) var flow: Flow?

    private var currentConfig: GroupConfig?
    private var pairingCode = ""
    private var roomId = ""
    private var pairingRelayURL = AppEnvironment.current.relayURL
    private var initiatorSalt: Data?
    private var joinerPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var joinerPublicKey: Data?

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var listenTask: Task<Void, Never>?
    private var delayedCloseTask: Task<Void, Never>?

    func startHosting(config: GroupConfig) {
        prepareForNewAttempt()
        flow = .hostedAddDevice
        currentConfig = config
        pairingCode = RelayCrypto.generatePairingCode()
        displayedCode = pairingCode
        roomId = RelayCrypto.derivePairingRoomId(from: pairingCode)
        pairingRelayURL = config.relayURL.absoluteString
        initiatorSalt = RelayCrypto.randomData(length: 32)

        DevLog.log("🔗 Pairing host opening room \(roomId.prefix(16))... for code \(pairingCode)")
        phase = .opening
        openSocket()
        send(RelayOutgoing.pairOpen(role: "initiator", roomId: roomId))
    }

    func join(code: String) {
        prepareForNewAttempt()
        flow = .join
        let normalized = RelayCrypto.normalizePairingCode(code)
        DevLog.log("🔗 PairingCoordinator.join raw=\(code) normalized=\(normalized)")
        guard normalized.count == 8 else {
            phase = .failed("Enter a valid pairing code")
            return
        }

        pairingCode = normalized
        roomId = RelayCrypto.derivePairingRoomId(from: normalized)
        pairingRelayURL = AppEnvironment.current.relayURL
        let privateKey = RelayCrypto.generateJoinerPrivateKey()
        joinerPrivateKey = privateKey
        joinerPublicKey = RelayCrypto.publicKeyData(from: privateKey)

        DevLog.log("🔗 Pairing join opening room \(roomId.prefix(16))... for code \(normalized)")
        phase = .opening
        openSocket()
        send(RelayOutgoing.pairOpen(role: "joiner", roomId: roomId))
    }

    func reset() {
        DevLog.log("🔗 Pairing reset called; phase=\(String(describing: phase))")
        closeConnection(sendCancel: true)
        clearState()
    }

    private func prepareForNewAttempt() {
        DevLog.log("🔗 Pairing prepareForNewAttempt called; phase=\(String(describing: phase))")
        closeConnection(sendCancel: false)
        clearState()
    }

    private func clearState() {
        delayedCloseTask?.cancel()
        delayedCloseTask = nil
        phase = .idle
        displayedCode = nil
        completedConfig = nil
        flow = nil
        currentConfig = nil
        pairingCode = ""
        roomId = ""
        pairingRelayURL = AppEnvironment.current.relayURL
        initiatorSalt = nil
        joinerPrivateKey = nil
        joinerPublicKey = nil
    }

    func cancel() {
        DevLog.log("🔗 Pairing cancel called; phase=\(String(describing: phase))")
        closeConnection(sendCancel: true)
    }

    private var isHosting: Bool {
        currentConfig != nil
    }

    private var isFinished: Bool {
        switch phase {
        case .complete, .failed:
            return true
        default:
            return false
        }
    }

    private func openSocket() {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 15
        sessionConfig.timeoutIntervalForResource = 60
        session = URLSession(
            configuration: sessionConfig,
            delegate: RelaySessionDelegate.shared,
            delegateQueue: nil
        )
        webSocketTask = session?.webSocketTask(with: URL(string: pairingRelayURL)!)
        webSocketTask?.resume()

        listenTask = Task { await listen() }
    }

    private func send(_ json: String?) {
        guard let json else { return }
        DevLog.log("📤 Pairing send: \(json)")
        let task = webSocketTask
        Task {
            do {
                guard let task else {
                    DevLog.log("ERROR: Pairing send skipped; socket was nil")
                    return
                }
                try await task.send(.string(json))
            } catch {
                DevLog.log("ERROR: Pairing send failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.phase = .failed("Pairing connection failed")
                    self.cancel()
                }
            }
        }
    }

    private func listen() async {
        guard let task = webSocketTask else { return }

        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let parsed: RelayMessage?

                switch message {
                case .string(let text):
                    parsed = RelayMessage.parse(from: text)
                case .data(let data):
                    parsed = RelayMessage.parse(from: data)
                @unknown default:
                    parsed = nil
                }

                if let parsed {
                    DevLog.log("📥 Pairing recv: \(String(describing: parsed))")
                }

                guard let parsed else { continue }
                await handle(parsed)
            } catch {
                DevLog.log("ERROR: Pairing receive failed: \(error.localizedDescription)")
                if !Task.isCancelled, !isFinished {
                    phase = .failed("Pairing connection closed")
                }
                closeConnection(sendCancel: false)
                return
            }
        }
    }

    private func handle(_ message: RelayMessage) async {
        DevLog.log("🔗 Pairing handle message: \(String(describing: message))")
        switch message {
        case .pairOpenOk:
            phase = isHosting ? .waitingForPeer : .waitingForInitiator

        case .pairReady:
            if isHosting, let initiatorSalt {
                send(RelayOutgoing.pairHello(salt: initiatorSalt.base64EncodedString()))
            }

        case .pairData(let data):
            if isHosting {
                await handleHosting(data)
            } else {
                await handleJoining(data)
            }

        case .pairCancel:
            phase = .failed("Pairing was cancelled")
            closeConnection(sendCancel: false)

        case .pairComplete:
            if isHosting {
                phase = .complete("Device connected")
                closeConnection(sendCancel: false)
            }

        default:
            break
        }
    }

    private func handleHosting(_ data: PairDataMessage) async {
        DevLog.log("🔗 handleHosting data=\(String(describing: data)) phase=\(String(describing: phase))")
        switch data {
        case .join(let salt):
            guard let joinerPublic = Data(base64Encoded: salt) else {
                DevLog.log("🔗 handleHosting invalid join salt")
                phase = .failed("Invalid join request")
                cancel()
                return
            }
            joinerPublicKey = joinerPublic
            phase = .verifying

        case .proofB(let proof):
            guard let initiatorSalt,
                  let joinerPublicKey,
                  let groupKey = currentConfig?.groupKey
            else {
                DevLog.log("🔗 handleHosting incomplete state initiatorSalt=\(initiatorSalt != nil) joinerPublicKey=\(joinerPublicKey != nil) groupKey=\(currentConfig?.groupKey != nil)")
                phase = .failed("Incomplete pairing state")
                cancel()
                return
            }

            let expected = RelayCrypto.derivePairProof(
                code: pairingCode,
                initiatorSalt: initiatorSalt,
                joinerPublicKey: joinerPublicKey,
                label: "B"
            )

            guard proof == expected else {
                DevLog.log("🔗 handleHosting proof mismatch expected=\(expected) actual=\(proof)")
                phase = .failed("Pairing code mismatch")
                cancel()
                return
            }

            guard let wrappedKey = RelayCrypto.wrapGroupKey(groupKey, to: joinerPublicKey)
            else {
                DevLog.log("🔗 handleHosting wrapGroupKey failed")
                phase = .failed("Key transfer failed")
                cancel()
                return
            }

            let proofA = RelayCrypto.derivePairProof(
                code: pairingCode,
                initiatorSalt: initiatorSalt,
                joinerPublicKey: joinerPublicKey,
                label: "A"
            )

            phase = .transferring
            send(RelayOutgoing.pairGrant(proof: proofA, wrappedKey: wrappedKey))

        default:
            break
        }
    }

    private func handleJoining(_ data: PairDataMessage) async {
        DevLog.log("🔗 handleJoining data=\(String(describing: data)) phase=\(String(describing: phase))")
        switch data {
        case .hello(let salt):
            guard let initiatorSalt = Data(base64Encoded: salt),
                  let joinerPublicKey
            else {
                DevLog.log("🔗 handleJoining invalid initiator data initiatorSaltB64Valid=\(Data(base64Encoded: salt) != nil) joinerPublicKey=\(joinerPublicKey != nil)")
                phase = .failed("Invalid initiator data")
                cancel()
                return
            }

            self.initiatorSalt = initiatorSalt
            phase = .verifying

            send(RelayOutgoing.pairJoin(salt: joinerPublicKey.base64EncodedString()))
            let proof = RelayCrypto.derivePairProof(
                code: pairingCode,
                initiatorSalt: initiatorSalt,
                joinerPublicKey: joinerPublicKey,
                label: "B"
            )
            send(RelayOutgoing.pairProofB(proof))

        case .grant(let proof, let wrappedKey):
            guard let initiatorSalt,
                  let joinerPrivateKey,
                  let joinerPublicKey
            else {
                DevLog.log("🔗 handleJoining incomplete state initiatorSalt=\(initiatorSalt != nil) joinerPrivateKey=\(joinerPrivateKey != nil) joinerPublicKey=\(joinerPublicKey != nil)")
                phase = .failed("Incomplete pairing state")
                cancel()
                return
            }

            let expected = RelayCrypto.derivePairProof(
                code: pairingCode,
                initiatorSalt: initiatorSalt,
                joinerPublicKey: joinerPublicKey,
                label: "A"
            )

            guard proof == expected else {
                DevLog.log("🔗 handleJoining proof mismatch expected=\(expected) actual=\(proof)")
                phase = .failed("Pairing code mismatch")
                cancel()
                return
            }

            guard let groupKey = RelayCrypto.unwrapGroupKey(
                wrappedKey,
                joinerPrivateKey: joinerPrivateKey
            ) else {
                DevLog.log("🔗 handleJoining unwrapGroupKey failed wrappedKey.ephemeralPub.len=\(wrappedKey.ephemeralPub.count) nonce.len=\(wrappedKey.nonce.count) ciphertext.len=\(wrappedKey.ciphertext.count)")
                phase = .failed("Could not receive group key")
                cancel()
                return
            }

            guard await sendPairCompleteAndFlush() else {
                phase = .failed("Could not finish pairing")
                closeConnection(sendCancel: false)
                return
            }

            completedConfig = GroupConfig(
                groupKey: groupKey
            )
            phase = .complete("Device connected")
            closeConnection(sendCancel: false)

        default:
            break
        }
    }

    private func sendPairCompleteAndFlush() async -> Bool {
        guard let json = RelayOutgoing.pairComplete(),
              let task = webSocketTask
        else {
            DevLog.log("ERROR: Pairing final ack skipped; socket was nil")
            return false
        }

        DevLog.log("📤 Pairing send (await): \(json)")
        do {
            try await task.send(.string(json))
            try? await Task.sleep(for: .milliseconds(300))
            return true
        } catch {
            DevLog.log("ERROR: Pairing final ack failed: \(error.localizedDescription)")
            return false
        }
    }

    private func closeConnection(sendCancel: Bool) {
        DevLog.log("🔗 Pairing closeConnection sendCancel=\(sendCancel) phase=\(String(describing: phase)) hasTask=\(webSocketTask != nil)")
        let task = webSocketTask
        if sendCancel, let task, let json = RelayOutgoing.pairCancel() {
            Task { try? await task.send(.string(json)) }
        }
        listenTask?.cancel()
        listenTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
    }
}
