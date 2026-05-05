# chat4000 — Future Features

Features deferred from V1, roughly ordered by priority.

---

## Reliable Delivery — Deferred Items (protocol §6.6)

The acknowledgement layer landed in v1 (App Nap blocker, 25 s heartbeat, `seq`, `recv_ack`, `relay_recv_ack`, inner `ack`, idempotent insert by `msg_id`, plugin-version-policy soft nag). The following are deliberately deferred:

- **R1.** App-to-app delivery ticks (§6.6.7 v1 restriction). In v1 the "delivered" tick reflects only that the plugin received the prompt; multi-app-device groups do not show "delivered to other app device". Apps do not emit inner `ack` frames for inbound `from.role == "app"` messages. A future protocol minor revision may relax this.
- **R2.** `stage:"processing"` and `stage:"displayed"` plugin acks. v1 uses only `stage:"received"` plus the streaming `text_delta` first-token as the implicit "agent typing" signal. Add a `processing` ack + a dedicated "agent typing" tick if the latency between plugin receipt and first-token feels laggy in practice.
- **R3.** Plugin-version `hardBlock` UX. `PluginVersionPolicyManager` already resolves to `hardBlock` when `plugin_version < min_version`, but the UI only renders the soft-nag banner today. Add a non-dismissible blocker view that gates the composer entirely (mirroring `UpgradeRequiredView` for app version).
- **R4.** Unit-test coverage for `AckTracker`, `AckSeqStore`, idempotent insert, and `PluginVersionPolicyManager`. Existing tests do not touch these paths.
- **R5.** Migration of legacy `ChatMessage` rows (those persisted before the `msgId` field landed). Their `msgId` defaults to `id.uuidString`, which never matches a wire `inner.id`, so on a relay redrive they would be inserted as new rows. One-time migration: walk the SwiftData store and null out `msgId` for any rows whose `msgId == id.uuidString` and the inner-id-format heuristic doesn't match (low priority — affects only old messages that pre-date the ack layer).
- **R6.** iOS background-task disconnect deferral. Explicitly skipped in this rollout. If iPhone-side message loss reappears (the iPhone closes the WS within ms of going to background), revisit by adding `beginBackgroundTask` on `sceneDidEnterBackground` to give the receive loop ~30 s to drain before close.

---

## V2 — Rich Chat + Platforms

- **A0.** macOS app — extend the SwiftUI codebase to support macOS (Sonoma 14+), wider layout, ⌘+Return to send, resizable window
- **A1.** Reply to specific message — swipe-to-quote UI (iMessage style), sends `replyToMessageId` in the envelope
- **A2.** Streaming responses — live token-by-token text appearing as the agent generates (typing indicator + progressive text)
- **A3.** Markdown rendering — render agent responses as formatted markdown (code blocks, bold, links, lists)
- **A4.** Full device pairing — challenge → signed nonce → device keypair → device token flow, replacing simple token auth
- **A5.** Tool approval UI — when the agent requests tool use, show an approval/deny prompt in-chat

## V3 — Media & Polish

- **B1.** Rich media messages — images, files, voice messages
- **B2.** Link previews — inline URL preview cards
- **B3.** Reactions — quick emoji reactions to messages
- **B4.** Search — full-text search through chat history
- **B5.** Light mode — optional light theme toggle
- **B6.** Custom notification sounds

## V4 — Multi-session & Power Features

- **C1.** Multiple session types — support OpenClaw's session scoping (per-channel-peer, per-peer, etc.)
- **C2.** Agent status dashboard — see what channels are connected, uptime, message volume
- **C3.** Shortcuts / Siri integration — "Hey Siri, ask my agent..."
- **C4.** Widgets — home screen / lock screen widget showing last message or agent status
- **C5.** Menu bar app (macOS) — quick-access popover from the menu bar
- **C6.** iPad layout — sidebar + chat split view
- **C7.** Watch app — quick replies from Apple Watch
