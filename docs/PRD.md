# chat94 — Product Requirements Document (V1)

## Overview

chat94 is a native iOS app (iPhone only for V1) for connecting to an [OpenClaw](https://github.com/openclaw/openclaw) server. OpenClaw is an open-source, self-hosted AI agent gateway that bridges messaging platforms (WhatsApp, Telegram, etc.) into a unified agent interface. chat94 gives you a direct, beautiful, native chat experience with your OpenClaw agent — no browser, no Telegram, no WhatsApp needed.

**Goal**: The simplest, prettiest way to talk to your OpenClaw agent from your iPhone.

---

## V1 Scope

### What it does

1. **Connect to one OpenClaw server** via the WebSocket gateway protocol
2. **Authenticate** using a simple gateway token (entered once, saved to Keychain)
3. **Chat** with the agent in a single plain-text conversation thread
4. **Receive server-pushed messages** (the agent can message you unprompted)
5. **Persist chat history locally** on-device using SwiftData
6. **Push notifications** with actual message content via a relay server
7. **Haptic feedback** on send and contextual interactions

### What it does NOT do (v1)

- Multiple servers or server switching
- Multiple conversations / channels
- Rich media (images, files, voice) — plain text only
- Streaming / live token-by-token display
- Reply-to-specific-message UI (swipe to quote)
- Markdown rendering in agent responses
- Full device pairing (challenge → signed nonce → device keys)
- Account creation or user registration
- End-to-end encryption beyond TLS
- Tool approval UI
- macOS app (deferred to V2)
- iPad support

---

## Connection Flow

### First launch — Setup Screen

A single centered card on a dark background with three fields:

| Field   | Description                             | Example              |
|---------|-----------------------------------------|----------------------|
| Server  | Hostname or IP of the OpenClaw instance | `agent.example.com`  |
| Port    | Gateway WebSocket port                  | `18789`              |
| Token   | Gateway authentication token            | `oc_tok_abc123...`   |

A **Connect** button initiates the WebSocket handshake. On success, the app transitions to the chat view and saves credentials to the Keychain. On failure, an inline error is shown below the button.

### Reconnection

The app automatically reconnects on network changes and app foregrounding. A colored dot in the nav bar shows connection state:
- **Green** — connected
- **Yellow** — reconnecting
- **Red** — disconnected

---

## OpenClaw Gateway Protocol (V1 subset)

- **Transport**: WebSocket (`ws://` or `wss://`)
- **Default port**: `18789`
- **Frame format**: JSON text frames
- **Auth**: Simple token auth via `connect.params.auth.token`

### Handshake (simplified, no device pairing)

1. Open WebSocket connection to `wss://{host}:{port}`
2. Server sends `connect.challenge` with nonce + timestamp
3. Client sends `connect` request with protocol version, client ID, role (`operator`), scopes, and auth token
4. Server responds with `hello-ok`

### Message envelopes

**Client → Server** (`WsClientEnvelope`):
```json
{
  "type": "user_message",
  "text": "Hello agent",
  "messageId": "client-generated-uuid"
}
```

**Server → Client** (`WsServerEnvelope`):
```json
{
  "type": "assistant_message",
  "text": "Hi! How can I help?",
  "inReplyToMessageId": "client-generated-uuid"
}
```

Server can also push events without a prior client message.

### Constraints

- Rate limit: 120 messages/min per connection
- Max message size: 65,536 bytes
- Max connections per IP: 50

---

## Push Notifications

### Architecture (Option A — Relay Server)

A lightweight Python (FastAPI + uv) service runs alongside the OpenClaw instance:

1. Relay connects to OpenClaw via WebSocket (always-on)
2. When OpenClaw sends a message, relay forwards it to APNs
3. iPhone/Mac receives a real push notification with the actual message text
4. Relay also persists messages server-side (so app reinstall can recover history)

The relay lives in this repo under `/relay-server/`.

### Notification behavior

- **Content**: Show the actual agent message text in the notification body
- **Title**: "chat94"
- **Sound**: Default iOS notification sound
- **Badge**: Unread message count

---

## UX & Design

### Aesthetic

- **Dark mode only** (v1)
- Near-black background (#0F0F0F)
- Minimalist, Notion/iMessage-inspired
- SF Pro typography, generous whitespace, subtle 0.2s animations
- No clutter — the chat is the entire app

### Screen 1 — Setup Screen

- Centered card on near-black background
- App icon (minimal claw/link symbol in accent blue #4A9EFF)
- "chat94" title, large bold white
- Three input fields: dark (#1E1E1E) with subtle border (#2A2A2A), rounded
- Full-width "Connect" button in accent blue
- Error text area below button in red (#FF4A4A)
- macOS: 400x500 centered window. iOS: full-screen, vertically centered

### Screen 2 — Chat Screen

- Full-screen chat on near-black background
- **Nav bar**: "chat94" title left, connection status dot + gear icon right
- **User messages**: Right-aligned, accent blue (#4A9EFF) bubble, white text
- **Agent messages**: Left-aligned, dark grey (#1A1A1A) bubble, light grey text (#E0E0E0), small claw icon on first message in a group
- Subtle grey timestamps below bubbles
- 12px spacing between messages, 24px between sender groups
- Auto-scroll to bottom on new messages
- **Input bar**: Fixed bottom, dark (#141414), rounded text field, blue send button (arrow-up) appears when text is entered
- iOS: keyboard avoidance with smooth animation
- macOS: Cmd+Return sends, Return adds newline

### Screen 3 — Settings Sheet

- Bottom sheet (iOS) / popover (macOS), dark (#141414)
- Server info with "Edit" button → returns to setup
- "Disconnect" button (red)
- "Clear Chat History" with confirmation dialog
- App version in small grey text

### Haptics

- **Send message**: light impact feedback
- **Message received** (while in-app): subtle soft feedback
- **Connect success**: success notification feedback
- **Connect failure**: error notification feedback

---

## Technical Architecture

### Stack

- **SwiftUI** multiplatform (single codebase, iOS 17+ / macOS 14+ Sonoma)
- **Swift 6** with strict concurrency
- **URLSessionWebSocketTask** for WebSocket (no third-party deps)
- **SwiftData** for local chat history
- **Keychain** for secure credential storage (via Security framework)
- **APNs** for push notifications (via relay server)

### Project structure

```
chat94/
├── Sources/
│   ├── App/              # App entry point, scene configuration
│   ├── Models/           # Message, ServerConfig, ConnectionState
│   ├── Gateway/          # WebSocket client, protocol envelopes, reconnection
│   ├── Views/            # ChatView, SetupView, SettingsView
│   └── Services/         # KeychainService, NotificationService
└── Resources/            # Assets, colors

relay-server/             # Python/FastAPI push notification relay (built later)
```

### Target platforms

- iOS 17.0+
- macOS 14.0+ (Sonoma)

---

## Data Model

### `ServerConfig`
- `host: String`
- `port: Int`
- `token: String` (Keychain, not SwiftData)

### `ChatMessage`
- `id: UUID`
- `text: String`
- `sender: enum { user, agent }`
- `timestamp: Date`
- `status: enum { sending, sent, failed }`

---

## Distribution

- **App Store name**: chat94
- **Apple Developer account**: Individual ($99/year) — required for APNs + TestFlight
- **Personal use** initially, public App Store listing later

---

## Success Criteria

- Connect to a running OpenClaw server and exchange messages within 30 seconds of first launch
- App feels native and fast — no web views, no loading spinners longer than 1s
- Messages persist across app restarts
- Push notifications with message content arrive within 5s when backgrounded
- Works on iOS 17+ and macOS 14+
- Haptic feedback feels natural and not excessive
