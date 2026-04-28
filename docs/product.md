# chat94 iOS/macOS Client — Product Specification

## Overview

chat94 is a native iOS and macOS app for communicating with an [OpenClaw](https://github.com/openclaw/openclaw) AI agent through a zero-knowledge relay server. All messages are end-to-end encrypted with XChaCha20-Poly1305 using a shared symmetric group key. The relay never sees plaintext. Push notifications are silent wake-ups — Apple never sees message content.

**Target users**: People who self-host OpenClaw and want a native mobile/desktop chat client for their AI agent.

**Platforms**: iOS 17.0+ (iPhone), macOS 14.0+ (Sonoma).

**Distribution**: App Store (com.neonnode.chat94app).

---

## Core Concepts

- **Group key**: A 32-byte (`256`-bit) cryptographically random symmetric secret. Created once for a user group and reused forever unless a future key-rotation feature is added.
- **Group ID**: `lowercase_hex(SHA-256(group_key_bytes))` — a 64-character hex string derived from the group key. Used by the relay for routing.
- **Pairing code**: A short, human-entered temporary code used to connect a new device.
- **Relay server**: A central WebSocket relay at `wss://relay.chat94.com/ws`.

---

## Features

### 1. Pairing

- **1.1** Single long-lived group key — the first initiator creates the permanent 32-byte group key. Later device pairings reuse that same key. Adding another device does not create a new permanent key.
- **1.2** Create pairing code — a paired client can enter pairing mode and generate a short code for adding another device.
- **1.3** Pairing code format — code is grouped for readability, short enough to type, uppercase, and excludes ambiguous characters. Recommended default: `XXXX-XXXX` using `ABCDEFGHJKLMNPQRSTUVWXYZ2346789`.
- **1.4** Join with pairing code — every new device joins with the temporary pairing code. Plugin flow is paste-only; client flow may support paste or QR.
- **1.5** QR support for clients — client-to-client flows may encode the temporary pairing code as a QR for convenience.
- **1.6** Immediate teardown on failure — if either side closes pairing mode or pairing fails, the flow closes immediately and returns to idle.

### 2. Storage & Persistence

- **2.1** Group config file — stored at `~/Library/Application Support/chat94/pair-config.json`. Contains `groupKeyBase64` (standard base64 encoding of the 32-byte key). Older configs may still contain `relayURLOverride`, but runtime always uses the fixed relay domain. Written with `Data.WritingOptions` `.atomic` and `.completeFileProtection`.
- **2.2** Chat message persistence — SwiftData `@Model` objects stored in the app's default SwiftData container (`ChatMessage.self`). Each message has: `id: UUID`, `text: String`, `sender: .user | .agent`, `timestamp: Date`, `status: .sending | .sent | .failed`. Loaded on app launch sorted by timestamp ascending.
- **2.3** Dev config — optional `dev-config.json` bundle resource with keys `sentryDsn`, `posthogApiKey`, `posthogHost`, and `posthogSessionReplayEnabled`. Read-only, not user-configurable.
- **2.4** No real Keychain usage — despite the `KeychainService` name, storage is file-based in Application Support (not the iOS Keychain). File protection provides encryption at rest.

### 3. Relay Connection

- **3.1** WebSocket connection to relay over TLS (`wss://`). Uses `URLSessionWebSocketTask`. Default relay URL: `wss://relay.chat94.com/ws`.
- **3.2** App Attest registration — the app can register an unregistered permanent group key on the relay before normal connection.
- **3.3** Auto-reconnect with exponential backoff — on connection loss: 2s → 4s → 8s → 16s → 32s → 60s max.
- **3.4** Ping/pong heartbeat — send `{ "version": 1, "type": "ping", "payload": null }` every 30 seconds.
- **3.5** Connection state — one of: `.disconnected`, `.connecting`, `.connected`, `.reconnecting`, `.failed(String)`.

### 4. End-to-End Encryption

- **4.1** Algorithm: XChaCha20-Poly1305 (AEAD) implemented through `swift-sodium` / libsodium on Apple platforms. Key = the 32-byte group key. Nonce = 24 random bytes per message. Ciphertext = encrypted plaintext + 16-byte Poly1305 tag appended.
- **4.2** Wire format: nonce and ciphertext are both standard base64-encoded in the `msg` envelope payload fields. Compatible with Rust relay (`chacha20poly1305` crate) and TypeScript plugin (`@noble/ciphers`).
- **4.3** Inner message format: the plaintext inside each encrypted blob is a JSON object: `{ "t": "<type>", "id": "<uuid>", "body": { ... }, "ts": <unix-ms> }`.

### 5. Messaging

- **5.1** Send plain text — user types in the input bar, taps send (or presses Return on iOS). The text is wrapped as an inner `text` message (`{ "t": "text", "id": "...", "body": { "text": "..." }, "ts": ... }`), encrypted, and sent as a relay `msg` envelope. The message appears immediately in the chat as `.sending`, updated to `.sent` after encryption succeeds.
- **5.2** Receive complete text — inner type `text`. Decrypted, displayed as an agent message bubble with haptic success feedback.
- **5.3** Receive streamed responses — inner types `text_delta` (streaming chunks with `{ "delta": "..." }` body, same `id` for all chunks in one response) followed by `text_end` (final complete text with `{ "text": "..." }` body). During streaming, the message bubble updates live. On `text_end`, the bubble finalizes and is persisted to SwiftData.
- **5.4** Agent thinking indicator — inner type `status` with `{ "status": "thinking" }`. Shows animated dots (3 circles pulsing with 0.2s staggered delay) + "Thinking" label + live elapsed-time counter (updated every 100ms via `TimelineView`). Cleared when any text/status message arrives.
- **5.5** Activity status indicators — relay-level `typing` / `typing_stop` are removed. Activity is carried only as encrypted inner `status` messages inside normal relay `msg` envelopes. The app currently reacts to agent-side `status` values such as `thinking`, `typing`, and `idle`.
- **5.6** Message persistence — all sent and received messages are stored in SwiftData. Loaded on launch. Survive app restarts.
- **5.7** Clear history — available in Settings. Deletes all `ChatMessage` objects from SwiftData with a confirmation dialog ("Clear all messages? This cannot be undone.").

### 6. Push Notifications

- **6.1** APNs device token — on launch, the app requests notification authorization, registers for remote notifications, stores the APNs token, and includes it in the `hello` payload's `device_token` field when available.
- **6.2** Silent push — the relay sends an APNs background push (`content-available: 1`, no alert/badge/sound). The app wakes in background, reconnects to the relay with the saved group config, drains queued messages (FIFO), decrypts locally, and presents a local notification.
- **6.3** Zero-knowledge — Apple never sees message content. The push notification is just a wake-up signal.

### 7. User Interface

All screens use dark mode only. Background: #0F0F0F. Card background: #141414. All typography is monospaced (SF Mono via `.system(.monospaced)`). Platform-specific font sizes: iOS is larger (title 28pt, body 15pt), macOS is compact (title 20pt, body 12pt).

#### 7.1 Welcome Screen

The initial pairing UI is pairing-code based.

Unpaired app actions:
- create a new group
- enter a pairing code from another client

Paired app actions:
- connect to chat
- open settings
- start pairing mode to generate a fresh temporary pairing code for another device

#### 7.2 Create Pairing Code Screen

Contents:
- generated short code in grouped format
- cancel button
- instruction text:
  - "Paste this code into the device you want to connect"

Behavior:
- if the user closes this screen, pairing mode ends immediately
- the code is not shown as a permanent credential

#### 7.3 Enter Pairing Code Screen

Contents:
- text field for temporary pairing code
- continue button
- optional QR scan button for client-to-client flow only

Behavior:
- plugin flow is paste only
- client flow may support paste or QR
- after entering the code, the app joins the temporary pairing room and waits for the initiator

#### 7.4 Pairing Progress Screen

States:
- waiting for peer
- verifying code
- receiving key
- paired
- cancelled

No detailed cryptographic error message is required. On mismatch or failure the flow simply closes and returns to idle.

#### 7.4 Connecting Screen

Full-screen dark background with vertically centered content.

- **Top**: Back button in nav bar area (chevron.left + "Back", secondary color)
- **Center**: Status icon — `ProgressView` spinner for connecting/reconnecting, `xmark.circle` (48pt, red) for failed
- **Status title** — "Connecting..." or "Connection Failed", nav-title font, white, center-aligned
- **Status subtitle** — contextual message (e.g., error string for failed), subtitle font, secondary color
- **Error message** (conditional) — red text on red-tinted background, full-width

#### 7.5 Chat Screen

Full-screen dark background. Three sections stacked vertically:

**Nav bar** (top):
- Left: "chat94" in nav-title font (monospaced bold 20pt iOS / 14pt macOS), white
- Right: connection status dot (10×10 circle, color per §3.6) + gear icon (`gearshape` SF Symbol, 18pt, secondary color). Gear opens Settings sheet.
- 16pt horizontal padding, 12pt vertical padding. Separated from content by a Divider.

**Message list** (scrollable center):
- `ScrollView` with `LazyVStack`, 12pt spacing between messages, 16pt vertical padding.
- Each message is a `MessageBubble`:
  - **User messages**: right-aligned. Text in light color (#F3F4F6) on transparent background with 1.5px border (#71767A). Asymmetric rounded rectangle: 18pt radius on all corners except bottom-right (4pt radius — the "tail"). Timestamp below in small grey (#666666).
  - **Agent messages**: left-aligned. Paw icon (12pt `pawprint.fill` in 28×28 dark box with 6pt radius) to the left. Text in #E0E0E0 on dark bubble (#1A1A1A). Same shape but tail on bottom-left. Timestamp below.
  - Message padding: 16pt horizontal, 12pt vertical inside bubbles.
- Auto-scrolls to newest message when count changes (0.2s ease-out animation).

**Thinking indicator** (conditional, between messages and input):
- Visible when `isAgentThinking` is true.
- HStack: 3 animated dots (6×6 circles, staggered 0.2s delay, 0.6s ease-in-out repeating animation) + "Thinking" label + live elapsed timer (updated every 0.1s, format "X.Xs", monospaced digits).
- 16pt horizontal padding, 8pt vertical. Background matches main background. Transitions with opacity + slide from bottom.

**Remote typing indicator** (conditional, below thinking indicator):
- Visible when remote encrypted inner `status` is `typing`. Cleared on inner `status: idle` or reply completion.
- HStack: 3 smaller animated dots (5×5, 0.15s stagger, 0.5s animation) + "Typing..." label.
- 16pt horizontal padding, 6pt vertical.

**Input bar** (bottom):
- Divider on top.
- HStack with 12pt spacing, 16pt horizontal padding, 8pt bottom padding.
- `TextField` with "Message ..." placeholder, multi-line (1–5 lines), 22pt corner radius, 16pt horizontal / 12pt vertical internal padding. Dark background (#1E1E1E) with 1px border (#2A2A2A). Monospaced input font.
- **Send button** (conditional): appears with scale+opacity animation when text is non-empty. White circle (36×36) with black `arrow.up` icon (16pt semibold). Sends message and clears field. Light haptic on send.
- On submit (Return key on iOS): sends message.
- `onChange` of text: updates local compose state only. Chat activity sent over the wire must use encrypted inner `status` messages (see §5.5).

#### 7.6 Settings Sheet

Bottom sheet (iOS, `.medium` detent with drag indicator) or popover. Dark card background (#141414).

Contents top to bottom:
- **Header**: "Settings" in sheet-title font + X close button (top-right)
- **Divider**
- **Pairing section**:
  - "Add Device" button
  - current group identifier
  - group key is not shown directly as the primary sharing mechanism
- **Disconnect button** — full-width, 48pt height, red (#FF4A4A) background, white text
- **Clear Chat History button** — full-width, 48pt height, dark background with border. Opens confirmation dialog.
- **Privacy section** — `Share diagnostics and analytics` toggle. When off, disables PostHog analytics/replay and Sentry crash/error reporting on that device.
- **Version** — "chat94 v1.0.0", caption font, timestamp color (#666666), bottom-aligned with 24pt padding

### 8. Platform Differences

| Feature | iOS | macOS |
|---------|-----|-------|
| QR scanner | AVFoundation metadata scanner | AVFoundation camera preview + Vision QR detection |
| Window size | Full-screen, system managed | Setup: 380pt wide, fixed. Chat: 950×700, resizable (min 380×400). Hidden title bar. |
| Haptics | UIImpactFeedbackGenerator / UINotificationFeedbackGenerator | No-op (Haptics.swift checks `#if os(iOS)`) |
| Keyboard | System keyboard with types (.URL, .numberPad) | Standard macOS text input |
| Sheet | `.presentationDetents([.medium])` | SwiftUI sheet |
| Push registration | APNs token + `remote-notification` background mode | APNs token support; signed runs require macOS provisioning for entitlements |

### 9. Observability

- **9.1** Sentry crash reporting — optional. Initialized at launch if `sentryDsn` exists in `dev-config.json` and the user has not disabled telemetry. Used for handled/unhandled errors only. `attachStacktrace` is enabled; traces and auto session tracking are disabled.
- **9.2** PostHog analytics — optional. Initialized at launch if `posthogApiKey` exists in `dev-config.json` and the user has not disabled telemetry. Used for explicit app analytics events only. Automatic error capture is disabled. Session replay is controlled by config and intended for future remote gating.

---

## Relay Protocol Reference

See `docs/protocol.md` for:
- the pairing protocol
- the session protocol
- push behavior

---

## Future Features

See `docs/FUTURE.md` and `docs/protocol.md` §5.6 for planned features including: media messages, reactions, message edit/delete, reply threading, tool approval UI, Markdown rendering, link previews, key rotation, multi-session, and Android registration via Play Integrity.
