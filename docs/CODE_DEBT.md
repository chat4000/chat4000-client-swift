# Code Debt

Known shortcuts, deferrals, and "do this later" items in the v2 (Matrix-over-gateway) client. Each entry: what it is, why it's deferred, the impact today, and the rough fix. Newest concerns first.

Last updated: 2026-06-01.

## E2EE history on a newly-added device

**What.** When a second (or later) device is added to the same account, it does **not** see past message history — only messages sent after it joined.

**Why.** The registrar does nothing for keys (protocol C.4: "E2EE setup is entirely the device's job"). The v2 `CryptoEngine` sets up the `OlmMachine` but does **not** enable key backup or any cross-device key-sharing/verification. New messages decrypt fine because the plugin's `shareRoomKey` fans the megolm key out to all of a user's devices; but the megolm keys for *older* messages were never shared to a device that didn't exist yet, and there's no backup to restore them from.

**Impact.** Multi-device users get a blank history on each new device. Single-device users are unaffected.

**Fix sketch.** Enable server-side key backup (megolm backup + recovery key / SSSS) so a new device can restore history, and/or implement cross-signing + device verification so existing devices share historical keys to a newly-verified one. Both are `matrix-sdk-crypto` features (`BackupKeys`, `BackupRecoveryKey`, `CrossSigningSecrets`, `Verification` are present in the vendored FFI) — they just aren't wired into `CryptoEngine` yet.

## Reconnect re-syncs from scratch

**What.** On a dropped gateway socket, `MatrixSession.handleSocketClosed` builds a fresh `GatewayClient` and starts a new sliding-sync without the previous `pos` cursor.

**Why.** Quickest correct reconnect; the new client has no `syncPos`.

**Impact.** Works, but each reconnect refetches the current sync window instead of resuming — extra bandwidth/latency, and a larger initial diff to process.

**Fix sketch.** Persist the last `pos` (per account) and pass it to `startSync` on reconnect, or keep the `GatewayClient` and re-`auth` in place instead of rebuilding.

## Token refresh just resends the same token

**What.** `GatewayClient.onReauthNeeded` → `MatrixSession` resends the existing access token; there's no refresh-token exchange.

**Why.** Blocked on an open server-side decision — protocol Appendix #2 (refresh tokens vs fixed-length tokens) is undecided.

**Impact.** If a device token actually expires, reauth fails and the user must re-pair.

**Fix sketch.** Implement the refresh-token flow once the protocol pins it down; persist + rotate the refresh token in `MatrixCredentialStore`.

## "Add Device" can't mint a code in-app

**What.** Settings → Add Device shows an explainer, not a code generator: to add a device you get a 6-digit code from the plugin and enter it on the new device.

**Why.** In v2 only the plugin reserves pairing codes (`/pair/register` is gated by the plugin's service token, C.1). MSC4108 QR login is not viable (the crypto-only FFI lacks the rendezvous+OIDC flow; MSC4108 is OAuth/OIDC, which doesn't fit the appservice-token auth model).

**Impact.** No in-app one-tap "provision this other device" — the user round-trips through the plugin. (Normal pairing of any device via a plugin code works fine.)

**Fix sketch.** Add a control-room `device.*` command so the app can ask its plugin to reserve a code (bound to the user) on demand, then display it.

## Inbound media limited to image + audio

**What.** `MatrixMessageTransport` maps inbound `m.image` and `m.audio`; `m.video` / `m.file` are ignored.

**Why.** The app only sends image/audio, and the UI has no video/file renderer.

**Impact.** A video/file from another client wouldn't render.

**Fix sketch.** Add `m.video`/`m.file` handling + a UI affordance if/when needed.

## Stale in-repo docs

**What.** `docs/architecture.md`, `docs/protocol.md`, `docs/status.md`, and `README.md` still describe the **v1 relay** architecture (XChaCha20, custom WebSocket relay, deleted files like `WebSocketClient`/`RelayCrypto`/`PairingService`).

**Why.** Not updated during the v2 migration.

**Impact.** Actively misleading to anyone reading them. The real protocol is the sibling repo `chat4000-backend-depolyment-and-docs/docs/protocol.md`.

**Fix sketch.** Rewrite them to the v2 gateway + standalone-crypto reality.

## Not yet verified end-to-end

**What.** The whole v2 stack compiles and passes unit tests, but no **live stage login** against a real plugin has been run — so a real turn decrypting/rendering, and the sliding-sync list params actually matching deployed Tuwunel (`SlidingSync.swift` flags this), are unconfirmed.

**Why.** Needs a live plugin + stage backend.

**Impact.** Unknown-unknowns in the live wire shapes.

**Fix sketch.** Pair against stage, watch a streamed turn + tool + media round-trip, fix whatever diverges.
