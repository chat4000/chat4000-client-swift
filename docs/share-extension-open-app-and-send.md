# Share Extension → opening the app / sending on share — findings & decisions

Status: **feature shelved (2026-06-17).** This doc captures everything learned so it
can be picked up later. No auto-open or in-extension-send code was written; the only
code change made was the cancel-loop bug fix (see "What WAS fixed").

---

## The original problem (user report)

Sharing an image from Google Photos / Apple Photos:
1. **doesn't open the app** on share, and
2. when you open the app afterward it shows a "which chat?" picker, and **pressing
   Cancel re-shows the dialog in a loop**.

These are two independent problems. (1) is a platform limitation; (2) was a real bug.

---

## What WAS fixed (and verified) — the cancel loop

**Commit `fa75a5c`** — "fix: stop shared-image picker re-opening in a loop when cancelled".

Root cause: the picker's `onCancel` re-armed the launch action via
`LaunchActionStore.set(.sendSharedImage)`. `set()` posts `didSetNotification`, which
`ChatView`'s `.onReceive` turns straight back into `handlePendingLaunchActionIfNeeded`
→ the picker. Because the queued images were never consumed on cancel, the implicit
"inbox has pending image" action also re-fired on every later foreground. Net: an
unkillable cancel → reopen loop.

Fix (3 files):
- `chat4000/Sources/Views/ChatView.swift` — added `cancelledShareIds: Set<String>`;
  `onCancel` records the queued inbox IDs instead of calling `LaunchActionStore.set`;
  `handlePendingLaunchActionIfNeeded` only treats queued images as an implicit send
  action when at least one pending ID hasn't been dismissed this run.
- `chat4000/Sources/Services/SharedImageInbox.swift` — added `pendingIds()`.
- `chat4000/ShareExtension/ShareViewController.swift` — corrected a stale header
  comment (it claimed it does NOT launch the host app, while the code best-effort does).

Verified live on the iOS simulator AND on a physical iPhone log: picker appears with
2+ chats, Cancel closes it and it does NOT reappear; foreground re-trigger with the
image still queued does not re-present (the `cancelledShareIds` gate). Image-saving
works for both Google Photos and Apple Photos (`pending=2` observed after a real share).

> If this doc is being used to re-pick-up the work and `fa75a5c` was reverted, this
> fix should be re-applied first — it is correct and independent of the open/send work.

---

## Problem 1 — auto-opening the app from a Share Extension: NOT POSSIBLE (reliably)

Deep-research conclusion (high confidence, multiple Apple sources):

- There is **no Apple-supported, App-Store-safe way** to launch/foreground the host
  app from a **Share Extension** on modern iOS (17/18/26). Deliberate Apple design.
  - Apple DTS (Quinn "The Eskimo!"), forum 779644 (Apr 2025): "there isn't a supported
    way to do this." Forum 764570: "App extensions are not allowed to open URLs
    directly… a deliberate design choice."
  - Apple Frameworks Engineer "Rico", forum 758790: "Share Extensions are not allowed
    to open apps; use completeRequest and not openURL (which is only for Today Extensions)."
- `NSExtensionContext.open(_:completionHandler:)` is documented as supported **only**
  by Today and iMessage extension points — Share extensions excluded; returns `false`.
  A universal link is treated no differently (the gate is the extension *type*, not the URL).
  - https://developer.apple.com/documentation/foundation/nsextensioncontext/1416791-openurl
- The responder-chain `openURL:` selector hack (the "WhatsApp trick") was the only thing
  that ever worked; **iOS 18 hardened against it** — it now force-returns false at runtime:
  `"BUG IN CLIENT OF UIKIT… Force returning false (NO)"` and does not foreground the app.
  - forum 764570; https://keyboardkit.com/blog/2024/09/11/ios18-breaks-selector-based-url-opening
- Apple's recommended alternative: **post a local notification** the user taps to open
  the app (forum 764570). Notification permission belongs to the app, not the extension.

### The two approaches already tried in this repo (git history)
- `7931729` — responder-chain `openURL:` walk only. FAILED (no UIApplication in a share
  extension's responder chain).
- `7a84948` (still in the code) — `NSExtensionContext.open` (custom scheme
  `chat4000://share-image`) + responder-chain fallback. FLAKY: works sometimes (seen in a
  device log), fails when the device is locked or the app is cold — i.e. exactly the
  documented Today-only restriction.

### Realistic options for "get back into the app after a share"
1. **Local notification → user taps → app opens** (Apple-recommended). Reliable,
   App-Store-safe, works locked/cold. Costs one tap.
2. **App-Group handoff (current)** — extension saves the image; app reads it on next
   manual foreground. Robust; doesn't open the app by itself.
3. Responder-chain hack — **dead on iOS 18+**, App-Store risk. Do not use.
4. `NSExtensionContext.open` — documented-unsupported for share extensions; returns false.

Recommendation: **#1 + #2** — keep the App-Group save, add a tappable local notification.

---

## Problem 2 — sending E2E-encrypted from the Share Extension (no app open)

Possible, but it means sharing the e2e crypto store across two processes (app +
extension), which risks corrupting encryption. Deep-research findings (primary sources;
the verify/synthesis pass was rate-limited, so treat as strong-but-not-fully-voted):

### Feasibility
- **matrix-rust-sdk now has an opt-in cross-process lock**: `CrossProcessLockConfig`
  with `MultiProcess { holder_name }` vs `SingleProcess` (no-op). PR
  https://github.com/matrix-org/matrix-rust-sdk/pull/6160 (merged ~Feb 2026). Multi-process
  store access is a *designed* capability — but recent, and our `MatrixSDKCrypto` package
  version must actually expose it (UNCONFIRMED).
- **Element itself filed multi-process crypto-store races** between app and extensions:
  https://github.com/element-hq/element-ios/issues/7618

### The dominant risk: `0xdead10cc`
- A backgrounded process holding a file lock on a shared-App-Group SQLite file is killed
  by iOS (`0xdead10cc`). Sources: https://github.com/signalapp/SQLCipherVsSharedData ,
  https://github.com/sqlcipher/sqlcipher/issues/255 , https://github.com/xmtp/xmtp-ios/issues/336 ,
  Apple TN2408 (https://developer.apple.com/library/archive/technotes/tn2408/_index.html).
- Mitigations: **WAL** journal mode (only jetsam'd if a write txn is open at suspend),
  never hold the lock across suspension, `NSFileCoordinator`/`flock` single-writer.
- Apple TN2408: concurrent shared-container access can corrupt data; YOU must synchronize.

### How the real apps do it
- **Signal** sends E2E from its share extension: the extension opens its OWN handle on
  the shared GRDB/SQLCipher DB (key from a shared keychain), runs the full protocol stack
  in-process, coordinates with `NSFileCoordinator` (single-writer). Sources:
  Signal-iOS `SignalShareExtension/ShareViewController.swift`,
  `SignalServiceKit/Storage/Database/GRDBDatabaseStorageAdapter.swift`.
- **Telegram** sends from its extension (`makeTempContext`) — but cloud chats are NOT
  E2E/ratcheting, so it is NOT a valid precedent. `Telegram/Share/ShareRootController.swift`.
- **WhatsApp** — no usable public detail.

### Options (ranked) for our Matrix/vodozemac stack
- **A (recommended, safest): app stays the ONLY crypto owner.** Extension saves image +
  target room to the App Group, then wakes the app in the background (silent push /
  `BGProcessingTask`) to encrypt + send. Only one process ever opens the crypto store →
  zero corruption risk. Near zero-tap. Risk: background-wake latency/reliability.
- **B: true in-extension send (Signal-style).** Move crypto store + creds to the App
  Group; build a shared framework target so the extension can link the crypto code; use a
  cross-process lock (matrix-rust-sdk `MultiProcess`, not a raw `flock`) + WAL +
  commit-before-release + brief holds; one-shot send over HTTPS CS API. Highest fidelity,
  **most work + most risk** (0xdead10cc, Megolm outbound-session index reuse →
  permanently undecryptable messages, store corruption). Locks make it *acceptable* but
  never *risk-free* — only Option A removes the bug class entirely. Extra mitigation:
  treat an extension send as session-rotating so any desync self-heals.
- **C: extension shows a chat picker + instant confirmation; app does the crypto send.**
  Fixes the "share did nothing" feeling without cross-process crypto. Medium effort, low risk.
- **D: local-notification handoff** (one tap). Bulletproof fallback.

### Why locks don't fully solve B
Locks serialize *concurrent* access (the main corruption vector) but cannot prevent a
process being **killed mid-operation** (jetsam / `0xdead10cc` / sheet dismissed). If the
Megolm ratchet advances but the new state isn't committed before death → desync →
undecryptable. Locks also need the SDK to *reload state on lock acquisition* (a raw file
lock alone isn't enough). Stale locks if a holder dies. Net: B is "acceptably safe with
care"; A is "structurally safe" because nothing is shared.

---

## Our stack (facts relevant to any future attempt)
- Matrix over a CUSTOM WebSocket gateway (`wss://gateway/ws`) + HTTPS media
  (`/_matrix/media/v3/upload`).
- E2E via `MatrixSDKCrypto` (vodozemac `OlmMachine`), SQLite crypto store at the app's
  PRIVATE container `~/Library/Application Support/chat4000/<env>/matrix-crypto/`.
  `CryptoEngine` is `@MainActor`.
- Credentials (`matrix-session.json`: accessToken, userId, deviceId, gatewayURL) — also
  PRIVATE container, NOT the App Group. (`Sources/Matrix/MatrixCredentialStore.swift`)
- App Group `group.com.neonnode.chat94app` currently holds ONLY the shared image inbox
  (`SharedImageInbox`): pending image files + a manifest + extension diagnostics.
- Send path: encrypt media (AES-256-CTR) → upload → `crypto.encryptAndSend` (Megolm
  room-key share → `m.room.encrypted`) → PUT over the gateway WS.
- ShareExtension target links only UIKit; no Matrix/crypto code.
- Room list for a picker is NOT yet in the App Group (would need caching there).

## Recommended path if/when resumed
1. Keep the cancel-loop fix (`fa75a5c`).
2. For "back into the app": local notification (Problem-1 #1) + App-Group handoff.
3. For "send without opening": **Option A** (app-owned crypto + background send). Only
   consider Option B if zero-tap in-extension send becomes a hard requirement, and first
   confirm `MatrixSDKCrypto` exposes the cross-process lock.
