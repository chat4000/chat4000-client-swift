# chat94 iOS/macOS Client — Implementation Status

Last updated: 2026-04-15

## Feature Status

| ID | Feature | Status | Notes |
|----|---------|--------|-------|
| **1. Pairing** | | | |
| 1.1 | Single long-lived group key | Partial | Current code does persist and reuse one 32-byte shared key, but the creation and later-sharing flows are still tied to the old onboarding path. |
| 1.2 | Create pairing code | Not Implemented | No temporary pairing-code generator or relay pairing-room flow exists in the client. |
| 1.3 | Pairing code format | Not Implemented | No normalized `XXXX-XXXX` code format or ambiguity-safe alphabet is implemented yet. |
| 1.4 | Join with pairing code | Partial | Current client can scan or paste a raw shared key, but it cannot yet join through a temporary pairing code flow. |
| 1.6 | Temporary pairing room | Not Implemented | No `pair_open` / `pair_ready` / `pair_data` relay mode exists in the app client. |
| 1.7 | Joiner temporary keypair | Not Implemented | No temporary joiner keypair is generated for pairing. |
| 1.8 | Code confirmation | Not Implemented | No proof exchange using initiator salt plus joiner public key is implemented. |
| 1.9 | Permanent key transfer | Not Implemented | Initiator cannot yet encrypt the permanent group key to the joiner temporary public key through the relay. |
| 1.10 | Immediate teardown on failure | Not Implemented | Pairing-room cancellation semantics are specified but not implemented. |
| **2. Storage** | | | |
| 2.1 | Pair config file | Implemented | `KeychainService.swift` saves `PairConfig` to `~/Library/Application Support/chat94/pair-config.json` with `.atomic` + `.completeFileProtection`. |
| 2.2 | Chat message persistence | Implemented | SwiftData `ChatMessage` model. Loaded on launch, inserted on send/receive, deleted on clear. |
| 2.3 | Dev config | Implemented | `dev-config.json` bundle resource read at launch for Sentry/PostHog keys. |
| 2.4 | Storage is file-based (not Keychain) | Implemented | Documented. File protection provides encryption at rest. |
| **3. Relay Connection** | | | |
| 3.1 | WebSocket over TLS | Implemented | `RelayClient` uses `URLSessionWebSocketTask`. Default URL: `wss://relay.chat94.com/ws`. |
| 3.2 | Temporary pairing room handshake | Not Implemented | No client support for `pair_open`, `pair_open_ok`, `pair_ready`, `pair_data`, `pair_complete`, or `pair_cancel`. |
| 3.3 | Pairing room lifecycle | Not Implemented | Relay-side room occupancy and teardown rules are now in the spec but not implemented in this client repo. |
| 3.4 | Normal hello handshake | Implemented | Existing `RelayClient` still sends `hello { role, pair_id, device_token? }` and handles `hello_ok` / `hello_error`. |
| 3.5 | App Attest registration | Implemented | `RelayClient` handles `KEY_NOT_REGISTERED` by running `challenge` → `register` through `AppAttestManager` and retrying `hello`. |
| 3.6 | Auto-reconnect with backoff | Implemented | 2s → 4s → 8s → 16s → 32s → 60s max. Resets on success. |
| 3.7 | Ping/pong heartbeat | Implemented | Sends `ping` every 30s. Reconnects if no `pong` within 60s. |
| 3.8 | Connection state display | Implemented | State enum, nav status dot, and simplified `ConnectingView` match the current normal relay flow. |
| **4. Encryption** | | | |
| 4.1 | XChaCha20-Poly1305 | Implemented | `RelayCrypto` uses `swift-sodium` / libsodium with a 24-byte nonce and appended 16-byte tag. |
| 4.2 | Wire format compatibility | Implemented | Unit-tested standard base64 nonce + ciphertext output. Matches relay/plugin contract: nonce separate, ciphertext includes appended tag. |
| 4.3 | Inner message format | Implemented | `InnerMessage` struct with type-discriminated body. Codable. Types: `text`, `text_delta`, `text_end`, `status`. |
| **5. Messaging** | | | |
| 5.1 | Send plain text | Implemented | `RelayClient.send(text:)` → encrypt → `msg` envelope. `ChatViewModel.send(text:)` creates SwiftData record. Blocked at runtime by 4.1. |
| 5.2 | Receive complete text | Implemented | Decrypt → decode `InnerMessage` → `ChatViewModel.receiveAgentText()`. Blocked at runtime by 4.1. |
| 5.3 | Receive streamed responses | Implemented | `text_delta` accumulates in `streamBuffers`, `text_end` finalizes. Live bubble update. Blocked at runtime by 4.1. |
| 5.4 | Agent thinking indicator | Implemented | `status { "thinking" }` sets `isAgentThinking` + `thinkingStartTime`. Animated dots + elapsed timer in ChatView. |
| 5.5 | Typing indicators | Implemented | Send: 3s debounce in `ChatViewModel.handleLocalTyping()`. Receive: `onTyping` callback from `RelayClient`. UI: animated "Typing..." row. |
| 5.6 | Message persistence | Implemented | SwiftData insert on send/receive. Load on launch. |
| 5.7 | Clear history | Implemented | Deletes all `ChatMessage` from SwiftData. Confirmation dialog in `SettingsSheet`. |
| **6. Push Notifications** | | | |
| 6.1 | APNs device token in hello | Implemented | `PushNotificationManager` requests notification authorization, registers for remote notifications, stores the APNs token, and includes it in `hello`. |
| 6.2 | Silent push handling | Implemented | iOS app now declares `remote-notification` background mode, installs platform app delegates, handles silent pushes, reconnects to the relay, and drains queued messages. |
| 6.3 | Zero-knowledge push | Implemented | Silent push contains no message body; the app wakes, reconnects, decrypts locally, and only then presents a local notification. |
| **7. User Interface** | | | |
| 7.1 | Welcome screen | Partial | Current welcome screen still presents the old scan/manual-key flow rather than pairing-code-first onboarding. |
| 7.2 | Create pairing code screen | Not Implemented | No UI exists to generate, display, and count down a temporary pairing code. |
| 7.3 | Enter pairing code screen | Not Implemented | No UI exists to enter a temporary pairing code for pairing-room join. |
| 7.4 | Pairing progress screen | Not Implemented | No dedicated pairing progress or cancellation screen exists yet. |
| 7.5 | Chat screen | Implemented | `ChatView.swift` with message list, thinking indicator, typing indicator, input bar. Updated for new `ConnectionState`. |
| 7.6 | Settings sheet | Partial | Current settings still expose raw shared-key UI. The new spec requires a single generic add-member pairing action instead. |
| **8. Platform** | | | |
| 8.1 | iOS 17.0+ | Implemented | iOS build verified on April 13, 2026 against iPhone 17 simulator (the local machine did not have an iPhone 16 runtime). |
| 8.2 | macOS 14.0+ | Implemented | macOS target builds successfully, including native QR scanning after replacing the crashing metadata-output path with Vision detection. |
| **9. Observability** | | | |
| 9.1 | Sentry | Implemented | Routed through `TelemetryManager`. Used for crashes/errors only; respects the in-app telemetry toggle. |
| 9.2 | PostHog | Implemented | Routed through `TelemetryManager`. Used for explicit analytics events only; crash/error autocapture is disabled. |

## Verification Status

| Check | Status |
|-------|--------|
| iOS build (`xcodebuild`) | Passed on April 13, 2026 using `platform=iOS Simulator,name=iPhone 17` |
| macOS build (`xcodebuild`) | Passed on April 13, 2026 with code signing disabled after adding APNs/App Attest entitlements |
| Unit tests | Passed on April 13, 2026 — 19 tests across crypto, protocol, pair config, and inner messages |
| Integration test (app → relay → plugin) | Not run in this repo |
| Protocol serialization tests | Implemented and passing for the old direct-key relay protocol only |
| Crypto roundtrip tests | Implemented and passing |
