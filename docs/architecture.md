# chat4000 iOS/macOS Client — Architecture

## Current State

The app is implemented around a shared group key stored in local config, relay-based transport, XChaCha20-Poly1305 encrypted messaging, App Attest-backed registration, APNs token registration, and silent-push wake handling.

---

## Project Structure

```
chat4000/
├── project.yml                      ← XcodeGen spec (not Package.swift)
├── Sources/
│   ├── App/
│   │   ├── chat4000App.swift     ← @main entry, screen routing, telemetry bootstrap, push wake wiring
│   │   └── PlatformAppDelegate.swift← iOS/macOS app delegate bridge for APNs registration + silent push callbacks
│   ├── Gateway/
│   │   ├── ProtocolModels.swift     ← Relay envelope types, inner message types, builders
│   │   └── WebSocketClient.swift    ← RelayClient: hello/register/challenge flows, message routing, heartbeat, reconnect
│   ├── Models/
│   │   ├── ChatMessage.swift        ← SwiftData @Model for persisted messages
│   │   ├── ConnectionState.swift    ← Enum: disconnected/connecting/connected/reconnecting/failed
│   │   └── ServerConfig.swift       ← GroupConfig model + shared-key parsing helpers
│   ├── Services/
│   │   ├── AppAttestService.swift   ← AppAttestManager: key generation + attestation against relay challenge
│   │   ├── AnalyticsEvent.swift     ← Explicit analytics event names + shared bucket helpers
│   │   ├── AppEnvironment.swift     ← Build-config snapshot (relay URL, storage namespace, kind)
│   │   ├── Crypto.swift             ← RelayCrypto: SHA-256 group ID, pairing URI helpers, XChaCha20-Poly1305 via swift-sodium
│   │   ├── DevLog.swift             ← Bundle-id-gated logger (NSLog + ~/Library/Caches/chat4000-dev.log)
│   │   ├── Haptics.swift            ← UIKit haptic feedback (iOS only, no-op on macOS)
│   │   ├── KeychainService.swift    ← File-based GroupConfig persistence (Application Support)
│   │   ├── LaunchActionStore.swift  ← Pending launch-action persistence (e.g. chat4000://record deep link)
│   │   ├── LegalConsent.swift       ← Terms acceptance state + reconsent modal
│   │   ├── PairingService.swift     ← PairingCoordinator: pair_open/data/complete state machine
│   │   ├── RelaySessionDelegate.swift ← URLSession delegate (TLS trust handling for dev relays)
│   │   ├── TelemetryManager.swift   ← Sentry/PostHog setup, privacy toggle, analytics capture routing
│   │   ├── TelemetryPreferences.swift ← Local persisted on/off switch for diagnostics + analytics
│   │   ├── VersionPolicy.swift      ← VersionPolicyManager + semver compare; gates upgrade UI from hello_ok.version_policy
│   │   ├── VoiceNotes.swift         ← Voice recorder + playback controller, waveform downsampling
│   │   └── PushNotificationService.swift ← APNs token storage, silent push handling, badge clearing, local notification wake path
│   └── Views/
│       ├── ChatView.swift           ← Chat UI + ChatViewModel (@Observable), upgrade nag banner
│       ├── ConnectingView.swift     ← Current single-state relay connection UI
│       ├── QRScannerView.swift      ← Shared QR scanner view
│       ├── SetupView.swift          ← Welcome, pairing-code entry, help screens
│       ├── SettingsSheet.swift      ← Settings actions, disconnect, clear history, plugin version, talk-to-team
│       ├── Theme.swift              ← Colors, fonts, spacing, radii (design tokens)
│       └── Components/
│           ├── CameraCaptureView.swift  ← UIImagePickerController wrapper (iOS only)
│           ├── MessageBubble.swift      ← User/agent bubble with asymmetric rounded corners
│           ├── TalkToTeamButton.swift   ← Shared "Chat with the team" button + caption callout, opens Telegram
│           └── VoiceMessageViews.swift  ← Voice waveform + playback strip
├── Resources/
│   ├── Assets.xcassets              ← App icon, colors
│   ├── chat4000.entitlements     ← iOS APNs + App Attest entitlements
│   ├── chat4000Mac.entitlements  ← macOS APNs + App Attest entitlements
│   ├── Info.plist                   ← iOS info plist
│   ├── Info-macOS.plist             ← macOS info plist
│   └── dev-config.json              ← Optional telemetry config: sentryDsn, posthogApiKey, posthogHost, replay flag
docs/
├── protocol.md                      ← Relay protocol specification (567+ lines)
├── product.md                       ← This product spec
├── architecture.md                  ← This file
├── status.md                        ← Implementation status tracker
├── PRD.md                           ← LEGACY: original PRD (pre-relay)
├── FUTURE.md                        ← Deferred features list
└── documentation-template.md        ← Documentation maintenance contract
```

---

## Build System

- **XcodeGen** (`project.yml`) generates the Xcode project. Not SPM-based.
- **Swift 6.0** with strict concurrency.
- Two targets sharing the same source:
  - `chat4000` — iOS app, iPhone only (`TARGETED_DEVICE_FAMILY: 1`)
  - `chat4000Mac` — macOS app
- **SPM Dependencies** (declared in `project.yml`):
  - `sentry-cocoa` ≥ 9.10.0 — crash reporting
  - `PostHog` ≥ 3.0.0 — product analytics
  - `swift-sodium` ≥ 0.9.1 — Swift wrapper around libsodium, used for XChaCha20-Poly1305
- Test target configured: `chat4000Tests` (iOS unit tests).

---

## Runtime Model

### App Lifecycle

1. `chat4000App.init()` — initialize telemetry from `dev-config.json` through `TelemetryManager`, then wire silent-push wake handling through `PushNotificationManager`
2. `body` builds a `WindowGroup` with a `Group` that switches on `currentScreen: AppScreen`
3. On appear: `checkSavedConfig()` loads `GroupConfig` from `KeychainService` → if found, routes directly to `.connecting`
4. `PlatformAppDelegate` requests remote notifications at launch and forwards APNs callbacks into the shared push service
5. Screen transitions driven by `currentScreen` state with `.easeInOut(0.3)` animations

### Actor Isolation

All UI and connection state is `@MainActor`:
- `RelayClient` — `@MainActor @Observable`
- `ChatViewModel` — `@MainActor @Observable`
- `chat4000App` — inherits main actor from SwiftUI `App`

Background work uses structured concurrency (`Task { }`, `Task.sleep`). Manual `DispatchQueue` usage remains in the QR scanner debounce/reset path, the macOS Vision frame queue, and macOS window management.

The registration and silent-push services mix actor-isolated state with platform callback entry points:
- `AppAttestManager` is an `actor` wrapping `DCAppAttestService`
- `PushNotificationManager` is `@MainActor` because APNs registration and notification presentation are app-lifecycle bound
- `BackgroundRelayWakeService` is `@MainActor` and owns short-lived relay reconnection work triggered from silent pushes

### State Observation

`ChatViewModel` polls `RelayClient`'s `@Observable` properties every 200ms in a loop:
```swift
Task { @MainActor in
    while true {
        connectionState = relay.state
        isAgentThinking = relay.isAgentThinking
        thinkingStartTime = relay.thinkingStartTime
        try? await Task.sleep(for: .milliseconds(200))
    }
}
```
This is a known design smell — it should use direct observation or callbacks. But it works and matches the original architecture.

---

## Data Model

### GroupConfig (file: ServerConfig.swift)

```swift
struct GroupConfig: Codable, Equatable {
    var groupKeyBase64: String       // Standard base64 of 32-byte key
    var relayURLOverride: String?    // legacy persisted field; runtime uses the fixed relay domain
}
```

Computed properties: `groupKey: Data?`, `groupId: String?` (SHA-256 hex), `relayURL: URL`, `isValid: Bool`.

Persisted as JSON at: `~/Library/Application Support/chat4000/pair-config.json`

### ChatMessage (file: ChatMessage.swift)

```swift
@Model final class ChatMessage {
    var id: UUID
    var text: String
    var sender: MessageSender    // .user | .agent
    var timestamp: Date
    var status: MessageStatus    // .sending | .sent | .failed
}
```

Managed by SwiftData. Container declared in `chat4000App`: `.modelContainer(for: ChatMessage.self)`. `ModelContext` injected via SwiftUI `@Environment(\.modelContext)` in `ChatViewWrapper`.

### ConnectionState (file: ConnectionState.swift)

```swift
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed(String)
}
```

---

## Data Flow

### Outbound Message (user → agent)

```
User taps Send
  → ChatViewModel.send(text:)
    → Creates ChatMessage(.user, .sending), inserts into SwiftData
    → RelayClient.send(text:)
      → InnerMessage.text(text) → JSONEncoder → plaintext bytes
      → RelayCrypto.encrypt(plaintext, pairKey) → (nonce_b64, ciphertext_b64)
      → RelayOutgoing.msg(nonce, ciphertext, msgId) → JSON envelope string
      → URLSessionWebSocketTask.send(.string(envelope))
    → Updates message status to .sent
```

### Inbound Message (agent → user)

```
URLSessionWebSocketTask.receive()
  → Raw text frame
  → RelayMessage.parse(from: text) → .msg(nonce, ciphertext, msgId)
  → RelayClient.handleMessage(.msg)
    → RelayCrypto.decrypt(nonce, ciphertext, pairKey) → plaintext bytes
    → JSONDecoder → InnerMessage
    → RelayClient.processInnerMessage(inner)
      → Updates isAgentThinking / thinkingStartTime
      → Calls onInnerMessage callback
  → ChatViewModel.handleInnerMessage(inner)
    → For .text: creates ChatMessage(.agent), inserts into SwiftData, haptic
    → For .textDelta: creates or updates streaming message bubble
    → For .textEnd: finalizes streaming message, persists to SwiftData, haptic
    → For .status: no-op (handled by relay's observable state)
```

### Connection Lifecycle

```
connect(config)
  → state = .connecting
  → URLSession + webSocketTask(with: relayURL)
  → webSocketTask.resume()
  → performHandshake(pairId)
    → Send hello JSON
    → Receive hello_ok → state = .connected, start heartbeat, listen loop
    → Receive hello_error(KEY_NOT_REGISTERED)
      → send challenge
      → receive challenge_ok(nonce)
      → AppAttestManager.attest(challengeBase64: nonce)
      → send register(pair_id, attestation, challenge)
      → receive register_ok
      → retry hello
    → Receive other hello_error → state = .failed(message)
    → Error → handleConnectionLoss()

handleConnectionLoss()
  → Cancel heartbeat + websocket
  → state = .reconnecting
  → Sleep retryDelay seconds
  → retryDelay *= 2 (max 60s)
  → connect(config) again
```

### Silent Push Wake Path

```
Relay sends APNs silent push
  → PlatformAppDelegate.didReceiveRemoteNotification(...)
  → PushNotificationManager.handleRemoteNotification(userInfo)
    → verify `aps.content-available == 1`
    → BackgroundRelayWakeService.handleSilentPush()
      → load saved PairConfig
      → create temporary RelayClient
      → connect to relay with same group key
      → drain queued encrypted messages
      → decrypt locally
      → present local notification for received text/text_end
      → disconnect temporary relay client
```

---

## Component Responsibilities

| File | Responsibility |
|------|---------------|
| `chat4000App.swift` | App entry, screen routing, telemetry bootstrap, config loading |
| `PlatformAppDelegate.swift` | OS app delegate bridge for APNs registration and silent push delivery |
| `RelayClient` (WebSocketClient.swift) | WebSocket lifecycle, hello handshake, App Attest registration retry, message routing, heartbeat, reconnect |
| `ProtocolModels.swift` | All relay wire types (envelopes, payloads), inner message types, JSON builders |
| `ChatViewModel` (ChatView.swift) | Message state, SwiftData persistence, typing indicators, inner message dispatch |
| `GroupConfig` (ServerConfig.swift) | Persisted permanent group key + relay URL, plus `group_id` derivation |
| `KeychainService.swift` | File-based PairConfig persistence in Application Support |
| `AppAttestService.swift` | App Attest key persistence, challenge hashing, attestation generation |
| `PushNotificationService.swift` | APNs registration state, silent push dispatch, local notification presentation, background relay wake |
| `Crypto.swift` | Group ID derivation (SHA-256), pairing URI helpers, XChaCha20-Poly1305 encrypt/decrypt using `swift-sodium` |
| `Theme.swift` | All design tokens: colors, fonts, spacing, radii |
| `Haptics.swift` | iOS UIKit haptic feedback (impact, success, error) |
| `ChatMessage.swift` | SwiftData model for persisted messages |
| `ConnectionState.swift` | Connection state enum |
| `WelcomeView` (SetupView.swift) | Welcome screen with scan QR + manual entry |
| `ManualKeyEntryView` (SetupView.swift) | Text input onboarding screen |
| `QRScannerView.swift` | Shared QR scanner UI, permission flow, AVFoundation camera preview, iOS metadata scanning, macOS Vision frame scanning |
| `ConnectingView.swift` | Connection progress display |
| `SettingsSheet.swift` | Settings with QR display, disconnect, clear history |
| `MessageBubble.swift` | Individual message rendering with asymmetric bubble shapes |

---

## External Dependencies

| Dependency | Purpose | Version |
|-----------|---------|---------|
| Relay server | Message routing, offline queue, APNs push | `wss://relay.chat4000.com/ws` |
| OpenClaw plugin | Agent-side relay connection | TypeScript, separate repo |
| Apple APNs | Silent background push wake-up | HTTP/2 |
| Apple App Attest | Group key registration anti-abuse | `DCAppAttestService` |
| Sentry | Crash reporting | ≥ 9.10.0 |
| PostHog | Product analytics + optional replay | ≥ 3.0.0 |
| swift-sodium / libsodium | E2E encryption | `from: 0.9.1`, resolved during verification to `0.10.0` |

---

## Testing Architecture

Current unit-test coverage lives in `chat4000/Tests/`:

- `CryptoTests.swift` — roundtrip, empty payload, max-size payload, wrong-key failure, corrupted-ciphertext failure, group-ID vector
- `ProtocolTests.swift` — outgoing `hello`/`challenge`/`register`/`pair_*` JSON validation (including `device_id` defaulting from `DeviceIdentity.currentDeviceId`), incoming message parsing, legacy `typing` frame ignore, malformed-JSON rejection
- `PairConfigTests.swift` — base64url/base64/URI parsing and group-ID validation
- `PairingCryptoTests.swift` — pairing code normalization, room ID derivation, X25519 wrap/unwrap roundtrip, proof encoding
- `InnerMessageTests.swift` — encode/decode roundtrip for all inner kinds, `text_end.reset` decoding, `TextBody` reset-omission in encoding, factory validation
- `VersionPolicyTests.swift` — resolver decision tree (no policy, all-null, hard-block, soft-nag, unparseable app version), semver compare, `hello_ok` parsing with and without `version_policy`

No UI tests are configured.

## Verification Status

Verified on April 13, 2026:

- `xcodegen generate`
- `xcodebuild -scheme chat4000Mac CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`
- `xcodebuild -scheme chat4000 -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build`
- `xcodebuild -scheme chat4000Tests -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' test`

Residual warnings:

- Asset catalog icon size warnings for macOS slots in `Assets.xcassets`
- **No integration tests** — relay and plugin are separate repos

---

## Known Limitations & Integration Gaps

1. **State polling at 200ms** — `ChatViewModel` still polls `RelayClient` state in a loop instead of using direct observation or callbacks.
2. **Background wake persistence is minimal** — Silent-push wake currently drains queued messages and posts local notifications, but does not write them into SwiftData when the UI is not active.
3. **Silent-push UX is intentionally sparse** — There is no special UI for "you missed N messages"; drained queue items are treated as normal messages once the foreground client reconnects.
4. **Signed macOS entitlement flow depends on provisioning** — APNs/App Attest entitlements are present, but real signed macOS runs need a valid team profile in Xcode.

---

## Distribution

### Mac DMG

`chat4000/scripts/build-dmg.sh` packages the macOS `chat4000mac` Release build into a signed, notarized DMG suitable for distribution outside the Mac App Store. The pipeline:

1. `xcodebuild archive` (Release config, hardened runtime enabled via `ENABLE_HARDENED_RUNTIME: YES` in `project.yml`)
2. `xcodebuild -exportArchive` with `method: developer-id` and `-allowProvisioningUpdates`
3. `create-dmg` with Applications drag-link and window layout
4. `xcrun notarytool submit --wait` (uses keychain profile `chat4000-notary`)
5. `xcrun stapler staple`

Pre-flight checks tell the user exactly what's missing if the script can't run: `create-dmg` not installed, no `Developer ID Application` cert for team `H45JD827CU`, or missing notary keychain profile.

One-time prerequisites:

- `brew install create-dmg`
- Generate a `Developer ID Application` cert for team `H45JD827CU` and import to login keychain
- Generate a Developer ID provisioning profile for `com.neonnode.chat4000app` (with Push + App Attest capabilities) and double-click to install
- `xcrun notarytool store-credentials chat4000-notary --apple-id … --team-id H45JD827CU --password <app-specific-password>`

### iOS

Distributed via the App Store (`chat4000iphoneappstore` target, `app_store` distribution channel for production builds, `appstore` release channel value sent to the relay). TestFlight uses the same `appstore` channel value but is detected via `appStoreReceiptURL` checking for `sandboxReceipt`. Dev builds use the `chat4000iphonedev` target with `.dev` bundle suffix and `dev` release channel.
