# chat94 iOS/macOS Client — Implementation Status

Last updated: 2026-04-28

## Feature Status

| ID | Feature | Status | Notes |
|----|---------|--------|-------|
| **1. Pairing** | | | |
| 1.1 | Single long-lived group key | Implemented | One 32-byte group key persists in `GroupConfig`, reused across reconnects and additional device pairings. |
| 1.2 | Create pairing code | Implemented | `RelayCrypto.generatePairingCode()` produces an 8-char `XXXX-XXXX` string from the ambiguity-safe alphabet. |
| 1.3 | Pairing code format | Implemented | Normalized uppercase, ambiguity-safe alphabet (`ABCDEFGHJKLMNPQRSTUVWXYZ2346789`), 8 characters. |
| 1.4 | Join with pairing code | Implemented | `EnterPairingCodeView` accepts pairing codes and `chat94://pair?code=…` URIs (including QR scan). |
| 1.5 | QR support for clients | Implemented | `QRScannerView` (AVFoundation on iOS, Vision on macOS); pairing initiator's `PairingProgressView` displays a QR for the code. |
| 1.6 | Temporary pairing room | Implemented | `PairingCoordinator` opens a `pair_open` room, drives `pair_data` exchange, and tears down on `pair_complete` / `pair_cancel`. |
| 1.7 | Joiner temporary keypair | Implemented | `Curve25519.KeyAgreement.PrivateKey()` per session; never persisted. |
| 1.8 | Code confirmation | Implemented | SHA-256 proofs over `code ‖ A_salt ‖ B_pub ‖ {"A","B"}` per `protocol.md` §5.5.1. |
| 1.9 | Permanent key transfer | Implemented | X25519 ECDH + SHA-256 derived key + XChaCha20-Poly1305 wrap of the 32-byte group key. |
| 1.10 | Immediate teardown on failure | Implemented | `PairingCoordinator.cancel()` sends `pair_cancel`, closes socket, returns to idle. |
| **2. Storage** | | | |
| 2.1 | Group config file | Implemented | `KeychainService.swift` saves `GroupConfig` to `~/Library/Application Support/chat94/<env-namespace>/group-config.json` with `.atomic` + `.completeFileProtection`. |
| 2.2 | Chat message persistence | Implemented | SwiftData `ChatMessage` model with text + image + audio. Loaded on launch, inserted on send/receive, deleted on clear. |
| 2.3 | Dev config | Implemented | `dev-config.json` bundle resource (gitignored) read at launch for Sentry/PostHog keys. |
| 2.4 | Storage is file-based (not Keychain) | Implemented | File protection provides encryption at rest. |
| **3. Relay Connection** | | | |
| 3.1 | WebSocket over TLS | Implemented | `RelayClient` uses `URLSessionWebSocketTask`. Default URL: `wss://relay.chat94.com/ws`. |
| 3.2 | Pairing room handshake | Implemented | `PairingCoordinator` handles `pair_open`, `pair_open_ok`, `pair_ready`, `pair_data`, `pair_complete`, `pair_cancel`. |
| 3.3 | Pairing room lifecycle | Implemented | Cancellation, disconnect, and proof-mismatch all teardown the room. |
| 3.4 | Hello handshake | Implemented | `RelayOutgoing.hello` includes `role`, `group_id`, `device_id`, `device_token` (when available), `app_id`, `app_version`, `release_channel`. |
| 3.5 | App Attest registration | Implemented | `RelayClient` handles `KEY_NOT_REGISTERED` by running `challenge` → `register` through `AppAttestManager` and retrying `hello`. |
| 3.6 | Auto-reconnect with backoff | Implemented | 2s → 4s → 8s → 16s → 32s → 60s max. Resets on success. |
| 3.7 | Ping/pong heartbeat | Implemented | Sends `ping` every 30s. Reconnects if no `pong` within 60s. |
| 3.8 | Connection state display | Implemented | State enum, nav status dot, `ConnectingView`. |
| 3.9 | Stable per-install device_id | Implemented | `DeviceIdentity.currentDeviceId` (UUID, persisted in `UserDefaults["chat94.device-id"]`). Sent on every hello and inside encrypted `from.device_id`. |
| 3.10 | Version policy | Implemented | `VersionPolicyManager` parses `hello_ok.version_policy`, hard-blocks below `min_version`, soft-nags below `recommended_version` (30-day snooze keyed on the version string). |
| **4. Encryption** | | | |
| 4.1 | XChaCha20-Poly1305 | Implemented | `RelayCrypto` uses `swift-sodium` / libsodium with a 24-byte nonce and appended 16-byte tag. |
| 4.2 | Wire format compatibility | Implemented | Standard base64 nonce + ciphertext, unit-tested. |
| 4.3 | Inner message format | Implemented | `InnerMessage` with type-discriminated body. Types: `text`, `image`, `audio`, `text_delta`, `text_end` (with optional `reset`), `status`. |
| **5. Messaging** | | | |
| 5.1 | Send plain text | Implemented | `RelayClient.send(text:)` → encrypt → `msg` envelope with `notify_if_offline=true`. |
| 5.2 | Receive complete text | Implemented | Decrypt → decode `InnerMessage` → `ChatViewModel.receiveText()`. |
| 5.3 | Receive streamed responses | Implemented | `text_delta` (cumulative-snapshot semantics, see `streaming.md`) accumulates, `text_end` finalizes. |
| 5.4 | Stream reset | Implemented | `text_end{reset:true}` deletes the streaming bubble for that `stream_id` (animated fade, SwiftData delete). |
| 5.5 | Agent thinking indicator | Implemented | `status: thinking` from the plugin sets `isAgentBusy` + `busyStartTime`; CLI-style spinner + elapsed timer in chat. |
| 5.6 | Activity status indicators | Implemented | Reacts to encrypted inner `status` messages (`thinking`, `typing`, `idle`); legacy outer `typing`/`typing_stop` are ignored. |
| 5.7 | Voice messages | Implemented | `VoiceNoteRecorder` (m4a 24kHz mono), live waveform, playback strip, encrypted as inner `audio`. |
| 5.8 | Image messages | Implemented | iOS camera capture via `UIImagePickerController`, encrypted as inner `image`. |
| 5.9 | Self-echo suppression | Implemented | `ChatViewModel` ignores inner messages where `from.role == .app && from.deviceId == DeviceIdentity.currentDeviceId`. |
| 5.10 | Message persistence | Implemented | SwiftData insert on send/receive. Load on launch. |
| 5.11 | Clear history | Implemented | Deletes all `ChatMessage` from SwiftData. Confirmation dialog in `SettingsSheet`. |
| **6. Push Notifications** | | | |
| 6.1 | APNs device token in hello | Implemented | Token registered, stored, included in every `hello`; refreshed automatically when APNs delivers a new token. |
| 6.2 | Silent push handling | Implemented | iOS `remote-notification` background mode, `PlatformAppDelegate` forwards silent pushes, `BackgroundRelayWakeService` reconnects + drains. |
| 6.3 | Zero-knowledge push | Implemented | Silent push contains no body; app wakes, decrypts locally, presents local notification. |
| 6.4 | Badge suppressed | Implemented | `.badge` not requested in auth; `setBadgeCount(0)` called on launch and every foreground transition. |
| **7. User Interface** | | | |
| 7.1 | Welcome / pairing-code entry | Implemented | `EnterPairingCodeView` with code field, QR scan, help menu, legal consent gate. |
| 7.2 | Create pairing code screen | Implemented | `PairingProgressView` shows the generated code as boxes + QR while hosting. |
| 7.3 | Enter pairing code screen | Implemented | Same `EnterPairingCodeView`; auto-submits when 8 chars entered. |
| 7.4 | Pairing progress screen | Implemented | `PairingProgressView` reflects coordinator phase: opening, waiting, verifying, transferring, complete/failed. |
| 7.5 | Chat screen | Implemented | `ChatView.swift` with message list, busy indicator, input bar (text + image + voice), settings sheet, soft-nag upgrade banner. |
| 7.6 | Settings sheet | Implemented | Add Device, Group ID, Plugin version, Privacy toggle, Disconnect, Clear Chat History, "Chat with the team" callout. |
| 7.7 | Help screens | Implemented | `helpMenuContent` with "Connect with paired device" and "Fresh plugin install" routes; both detail screens have terminal-command step cards and a Telegram callout. |
| 7.8 | Upgrade required screen | Implemented | `UpgradeRequiredView` shown when relay sends a `min_version` higher than `app_version`; replaces all other screens. |
| 7.9 | Upgrade recommended banner | Implemented | `UpgradeRecommendedBanner` in `ChatView`; dismissible, snoozed 30 days per recommended version. |
| 7.10 | Legal consent gate | Implemented | `LegalReconsentModal` blocks the app when `current_terms_version` exceeds the stored accepted version. |
| **8. Platform** | | | |
| 8.1 | iOS 17.0+ | Implemented | iOS 17 simulator + physical iPhone 17 Pro Max verified. |
| 8.2 | macOS 14.0+ | Implemented | `chat94mac` target builds and runs; native QR scanning via Vision; hardened runtime enabled. |
| 8.3 | Mac DMG distribution | Implemented (signed; notarization pending) | `chat94/scripts/build-dmg.sh` produces a Developer ID-signed, create-dmg-packaged DMG and submits to Apple Notary; staple step pending verification. |
| **9. Observability** | | | |
| 9.1 | Sentry | Implemented | Routed through `TelemetryManager`. Used for crashes/errors only; respects the in-app telemetry toggle. |
| 9.2 | PostHog | Implemented | Routed through `TelemetryManager`. Used for explicit analytics events only; crash/error autocapture is disabled. |
| 9.3 | DevLog file | Implemented | Bundle-id-gated (`*.dev` only) plain-text log at `<app sandbox>/Library/Caches/chat94-dev.log`. Pullable via `xcrun devicectl device copy from --domain-type appDataContainer`. |

## Verification Status

| Check | Status |
|-------|--------|
| iOS build (`xcodebuild`) | Passed on 2026-04-28 against iPhone 17 simulator and physical iPhone 17 Pro Max |
| macOS build (`xcodebuild`) | Passed on 2026-04-28 (Debug + Release) |
| Unit tests | Passed on 2026-04-28 — 48 tests across crypto, protocol, pair config, pairing crypto, inner messages, version policy |
| Mac DMG pipeline | Build + sign + DMG packaging verified; first notarization round-trip in progress |
| Integration test (app → relay → plugin) | Not run in this repo |
