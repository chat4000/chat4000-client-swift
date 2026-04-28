# chat94 — Future Features

Features deferred from V1, roughly ordered by priority.

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
