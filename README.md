<div align="center">

<img src="docs/images/icon.png" alt="chat4000" width="120" height="120" />

# chat4000

**Native iOS & macOS chat for your self-hosted [OpenClaw](https://github.com/openclaw/openclaw) agent.**
Beautiful. End-to-end encrypted. Zero-knowledge relay. No middleman reads a thing.

[chat4000.com](https://chat4000.com) · [@chat4000official](https://t.me/chat4000official) · contact@chat4000.com

</div>

<div align="center">

<img src="docs/images/iphone-bezel.png" alt="chat4000 on iPhone" width="280" />

<sub><b>iPhone</b></sub>

<br/><br/>

<img src="docs/images/mac.png" alt="chat4000 on Mac" width="820" />

<sub><b>Mac</b></sub>

</div>

---

## ✨ What's inside

- 🔐 **End-to-end encrypted.** XChaCha20-Poly1305 against a shared 32-byte group key. The relay never sees plaintext.
- 📲 **Native everywhere.** SwiftUI on iOS 17+ and macOS 14+ Sonoma. Single codebase, two beautiful targets.
- 🤝 **Pairing-code onboarding.** 8-character code, single-use, X25519 + SHA-256 proof, encrypted group-key transfer.
- ⚡️ **Streamed replies.** Live token-by-token agent responses with cumulative `text_delta` handling.
- 🎙️ **Voice, image, text.** Voice messages with waveforms, in-app camera capture, plain text — all encrypted.
- 🔔 **Silent push wake.** APNs delivers a content-less ping; your device wakes, drains the queue, decrypts locally. Apple never sees your messages.
- 🛡️ **App Attest.** Group keys are gated by Apple's hardware-attested device check — no spammer can register a key from a script.
- 📊 **Privacy by default.** Sentry crash reports and PostHog analytics are opt-in via an in-app toggle. Off → nothing leaves the device.
- 🚦 **Version policy.** The relay can softly nag or hard-block outdated clients without disconnecting them.

---

## 🛠 Build

The project is generated from `chat4000/project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) — no `.xcodeproj` workspace state is committed.

```bash
brew install xcodegen
cd chat4000
xcodegen generate
open chat4000.xcodeproj
```

### 🎯 Targets

| Scheme | Bundle ID | Notes |
|---|---|---|
| `chat4000iphonedev` | `com.neonnode.chat4000app.dev` | 🧪 Dev iPhone — verbose logging, dev APNs/App Attest |
| `chat4000iphoneprod` | `com.neonnode.chat4000app` | Internal release |
| `chat4000iphoneappstore` | `com.neonnode.chat4000app` | 🏪 App Store distribution |
| `chat4000mac` | `com.neonnode.chat4000app` | 🖥️ macOS app |
| `chat4000Tests` | — | ✅ Unit tests (Swift Testing) |

### 🔧 Command-line builds

```bash
# iOS simulator
xcodebuild -project chat4000/chat4000.xcodeproj \
  -scheme chat4000iphoneprod \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build

# macOS (no signing — local only)
xcodebuild -project chat4000/chat4000.xcodeproj \
  -scheme chat4000mac \
  CODE_SIGNING_ALLOWED=NO build

# Tests
xcodebuild -project chat4000/chat4000.xcodeproj \
  -scheme chat4000Tests \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```

### 📦 DMG distribution

A signed, notarized macOS DMG is one command away:

```bash
chat4000/scripts/build-dmg.sh                # full pipeline (sign + notarize + staple)
chat4000/scripts/build-dmg.sh --no-notarize  # quick local DMG, skip Apple round-trip
```

Output lands in `chat4000/build/dist/chat4000-<version>.dmg`. The script's pre-flight checks tell you exactly what's missing if it can't run yet (Developer ID cert, notary keychain profile, `create-dmg`).

### 🔑 Optional dev config

Telemetry keys live in `chat4000/Resources/dev-config.json` (gitignored). Without it, Sentry and PostHog stay quiet:

```json
{
  "sentryDsn": "...",
  "posthogApiKey": "...",
  "posthogHost": "https://us.i.posthog.com",
  "posthogSessionReplayEnabled": false
}
```

---

## 🗂 Project layout

```
chat4000/
├── 📋 project.yml                 XcodeGen spec
├── Sources/
│   ├── 🚀 App/                    Entry point, app delegate, intents
│   ├── 📡 Gateway/                Relay client, wire types, codecs
│   ├── 📦 Models/                 SwiftData + value types
│   ├── ⚙️  Services/              Crypto, App Attest, push, telemetry, pairing, …
│   └── 🎨 Views/                  SwiftUI screens, Theme, Components
├── 🎒 Resources/                  Assets, Info.plist, entitlements
└── 🧪 Tests/                      Crypto, protocol, pairing, version-policy tests

docs/
├── 🏗  architecture.md            Runtime model, data flow, components
├── 🌐 protocol.md                 Relay wire protocol (pairing + session)
├── 📘 product.md                  Feature spec
├── 🌊 streaming.md                text_delta / status semantics for clients
├── ✅ status.md                   Implementation status tracker
└── 🔮 FUTURE.md                   Deferred features
```

📖 **Where to start in the docs:**
- New here? → [`docs/architecture.md`](./docs/architecture.md) — runtime model, who calls what.
- Implementing the relay or a new client? → [`docs/protocol.md`](./docs/protocol.md) — the wire contract.
- Streaming behaving weirdly? → [`docs/streaming.md`](./docs/streaming.md) — the gotchas.

---

## 🧬 Related repos

- 🦀 **Relay** — Rust WebSocket relay (separate repo)
- 🔌 **OpenClaw plugin** — TypeScript bridge between OpenClaw agents and the relay (separate repo)

---

## 🤝 Contributing

PRs welcome. You'll need to sign a CLA — see [CONTRIBUTING.md](./CONTRIBUTING.md). Reach the team on [chat4000.com](https://chat4000.com), email at contact@chat4000.com, or Telegram at [@chat4000official](https://t.me/chat4000official) — we usually reply within a day.

---

## 📜 License

chat4000 is licensed under the **GNU General Public License v3.0** (GPL-3.0). See [LICENSE](./LICENSE).

Copyright © 2026 NeonNode Limited. All rights reserved.

**Commercial licensing:** Want to use chat4000 in a way GPL-3.0 doesn't allow (e.g. proprietary/closed-source use)? Reach out at contact@chat4000.com.

<div align="center">

Built by [NeonNode](https://chat4000.com)

</div>
