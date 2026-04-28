# chat94

[chat94.com](https://chat94.com) · Native iOS and macOS client for talking to a self-hosted [OpenClaw](https://github.com/openclaw/openclaw) AI agent.

Messages are end-to-end encrypted with XChaCha20-Poly1305 against a shared 32-byte group key. The relay never sees plaintext, and APNs silent pushes wake the app to drain queued messages locally — Apple never sees content either.

## Platforms

- iOS 17.0+ (iPhone)
- macOS 14.0+ (Sonoma)

## Features

- Pairing-code based device onboarding (8-char code, single-use, X25519 + SHA-256 proof, encrypted group-key transfer)
- Zero-knowledge relay transport (WebSocket + TLS)
- Streamed agent replies with cumulative `text_delta` handling
- Voice messages, image capture, plain text
- Per-device offline queue with APNs silent-push wake
- App Attest registration to prevent group-key abuse
- Optional Sentry crash reporting and PostHog analytics, gated by an in-app privacy toggle
- Forced and recommended version policy from the relay (hard-block / soft-nag)

## Build

The project is generated from `chat94/project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) — there is no committed `.xcodeproj` workspace state.

```bash
brew install xcodegen
cd chat94
xcodegen generate
open chat94.xcodeproj
```

### Targets

| Scheme | Bundle ID | Notes |
|---|---|---|
| `chat94iphonedev` | `com.neonnode.chat94app.dev` | Dev iPhone target — verbose logging, dev APNs/App Attest |
| `chat94iphoneprod` | `com.neonnode.chat94app` | Internal release target |
| `chat94iphoneappstore` | `com.neonnode.chat94app` | App Store distribution |
| `chat94mac` | `com.neonnode.chat94app` | macOS app |
| `chat94Tests` | — | Unit tests (Swift Testing) |

### Command-line builds

```bash
# iOS simulator
xcodebuild -project chat94/chat94.xcodeproj \
  -scheme chat94iphoneprod \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build

# macOS (no signing)
xcodebuild -project chat94/chat94.xcodeproj \
  -scheme chat94mac \
  CODE_SIGNING_ALLOWED=NO build

# Tests
xcodebuild -project chat94/chat94.xcodeproj \
  -scheme chat94Tests \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```

### Optional dev config

Telemetry keys live in `chat94/Resources/dev-config.json` (gitignored). Without it, Sentry and PostHog stay disabled. Schema:

```json
{
  "sentryDsn": "...",
  "posthogApiKey": "...",
  "posthogHost": "https://us.i.posthog.com",
  "posthogSessionReplayEnabled": false
}
```

## Project layout

```
chat94/
├── project.yml                 XcodeGen spec
├── Sources/
│   ├── App/                    Entry point, app delegate, intents
│   ├── Gateway/                Relay client, wire types, codecs
│   ├── Models/                 SwiftData + value types
│   ├── Services/               Crypto, App Attest, push, telemetry, pairing, …
│   └── Views/                  SwiftUI screens, Theme, Components
├── Resources/                  Assets, Info.plist, entitlements
└── Tests/                      Crypto, protocol, pairing, version-policy tests

docs/
├── architecture.md             Runtime model, data flow, components
├── protocol.md                 Relay wire protocol (pairing + session)
├── product.md                  Feature spec
├── streaming.md                text_delta / status semantics for clients
├── status.md                   Implementation status tracker
└── FUTURE.md                   Deferred features
```

For the full architecture, start at [`docs/architecture.md`](./docs/architecture.md). For the relay wire format, see [`docs/protocol.md`](./docs/protocol.md). For why streaming has surprising semantics, [`docs/streaming.md`](./docs/streaming.md) is the contract.

## Related repos

- **Relay** — Rust WebSocket relay (separate repo)
- **OpenClaw plugin** — TypeScript plugin that bridges OpenClaw agents into the relay (separate repo)

## Contributing

Pull requests are welcome. You'll need to sign a CLA — see [CONTRIBUTING.md](./CONTRIBUTING.md). Reach the team via [chat94.com](https://chat94.com), email at contact@chat94.com, or Telegram at [@chat94official](https://t.me/chat94official).

## License

chat94 is licensed under the **GNU General Public License v3.0** (GPL-3.0). See [LICENSE](./LICENSE).

Copyright © 2026 NeonNode Limited. All rights reserved.

**Commercial licensing:** If you want to use chat94 in a way that GPL-3.0 doesn't allow (e.g. proprietary/closed-source use), contact contact@chat94.com.
