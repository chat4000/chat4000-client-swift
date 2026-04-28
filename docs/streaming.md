# Agent Streaming Protocol — Implementation Guide for Clients

**Audience:** anyone implementing the *app* side of chat94 — receiving and rendering streamed replies from an OpenClaw agent through the relay. This is the contract, the timeline, the gotchas, and a reference implementation.

**Status:** current as of 2026-04-18, based on verified reads of:
- Plugin: `chat94-plugin/src/channel.ts`, `src/send.ts`, `src/types.ts`
- OpenClaw: `vendor/openclaw/src/auto-reply/reply/agent-runner-execution.ts`, `src/agents/pi-embedded-subscribe.*.ts`
- Swift reference client: `chat94/Sources/Gateway/WebSocketClient.swift`, `chat94/Sources/Views/ChatView.swift`

---

## 1. The data flow

```
Anthropic streaming API
      |
      v
OpenClaw agent runner                 (vendor/openclaw)
      |  fires typed callbacks: onAssistantMessageStart,
      |  onReasoningStream, onReasoningEnd, onPartialReply,
      |  onToolStart, onCompactionStart/End
      v
chat94 plugin  (src/channel.ts)
      |  translates callbacks into relay inner messages:
      |  status, text_delta, text_end, text
      v
Relay (zero-knowledge)                (ciphertext passthrough)
      |
      v
App client  (this guide)
      |  decrypts, accumulates, renders
```

The app-side client's job is entirely in the last step: take a stream of decrypted **inner messages** and turn them into UI.

---

## 2. Inner message types the client must handle

Four types carry reply data. All arrive inside encrypted `msg` envelopes and are JSON-decoded after decryption.

| Type | Body shape | Meaning |
|---|---|---|
| `text` | `{ text: string }` | Complete, non-streamed reply. Used when the agent returns a full reply in one shot (no streaming). |
| `text_delta` | `{ delta: string }` | A **cumulative** snapshot of the streamed text so far. See §4 — this is the single biggest gotcha. |
| `text_end` | `{ text: string, reset?: boolean }` | Streaming complete. `text` contains the **full final text**, authoritative. If `reset == true`, the stream is being **abandoned** — see §4a. |
| `status` | `{ status: "thinking" \| "typing" \| "idle" }` | Agent-side state signal. See §3. |

Every inner message also carries `id` (stream id for `text_delta` / `text_end`, or message id for `text`) and `ts`.

Unknown inner types MUST be tolerated silently — the plugin may add more over time. Do not crash or drop the connection.

---

## 3. The `status` values — the subtle one

Three values, three meanings, and one shared source of confusion:

### `"thinking"`

- **Meaning:** the model is in a reasoning phase. No visible text is being produced yet.
- **Emitted by plugin** (`chat94-plugin/src/channel.ts`):
  - `:466` on `onReasoningStream` — **once per thinking chunk**, so many times per reasoning phase
  - `:486` on `onToolStart` — once per tool invocation
  - `:489` on `onCompactionStart` — once per compaction event
- **Client action:** show a "thinking" state. Do not reset any timer on each repeat; the plugin floods these during reasoning.

### `"typing"` — **NOT "stop thinking"**

- **Meaning:** the model is **actively streaming text tokens**. More `text_delta` messages are coming.
- **Emitted by plugin** (`chat94-plugin/src/channel.ts`):
  - `:379` at reply-pipeline start
  - `:419` **with every single `text_delta`** during streaming
  - `:469` after `onReasoningEnd`
  - `:473` on `onAssistantMessageStart`
  - `:483` from `onPartialReply`
  - `:492` after `onCompactionEnd`
- **Client action:** treat this as a per-chunk **heartbeat** indicating active streaming. **DO NOT interpret `typing` as "stop thinking" or "reply done".** It is the most common message type during a reply and fires dozens of times.

### `"idle"`

- **Meaning:** the reply is fully complete. No more text, no more thinking.
- **Emitted by plugin:** `:430`, `:440`, `:451`, `:461`, `:499` — at every terminal path (normal completion, empty reply, non-streaming reply, error, fallback).
- **Client action:** the reply is done. Clear any "busy" UI.

### Summary

Only `idle` means "reply is over". Only `thinking` means "reasoning, not text yet". Everything else (`typing`, unknown values) should leave your busy/thinking state unchanged.

---

## 4. `text_delta` is **cumulative**, not incremental

**This is the gotcha that has bitten every client implementation so far.**

Each `text_delta.body.delta` contains the **entire text assembled so far**, not just the new characters since the previous delta. So the stream looks like:

```
text_delta { delta: "A" }
text_delta { delta: "A hard" }
text_delta { delta: "A hard one" }
text_delta { delta: "A hard one is" }
text_delta { delta: "A hard one is Newcomb's" }
text_delta { delta: "A hard one is Newcomb's problem." }
text_end   { text:  "A hard one is Newcomb's problem." }
```

### The bug you'll hit if you get this wrong

Naively doing `buffer += delta` (which is what "delta" usually implies in streaming APIs) produces this:

```
"A" + "A hard" + "A hard one" + "A hard one is" + ... =
"AA hardA hard oneA hard one is..."
```

— a progressively degrading concatenation mess. This is what chat94's Swift client initially shipped and the visual bug was obvious.

### Where this comes from in the plugin

`chat94-plugin/src/channel.ts:417-419`:

```typescript
lastText += text;                                      // plugin's own accumulator
sendStreamDelta(ctx.account.groupId, streamId, text);  // sends `text` to the wire
sendStatus(ctx.account.groupId, "typing");
```

`text` here comes from OpenClaw's `onPartialReply` callback (`vendor/openclaw/src/auto-reply/reply/agent-runner-execution.ts:938`), which in practice passes the full cumulative text — not an incremental chunk. The plugin forwards it unchanged.

The naming (`delta`) is misleading. Treat the field as a **cumulative snapshot**.

### Correct client handling

Two safe options:

**Option A — replace:**
```
if (inner is text_delta):
    stream_buffer[inner.id] = inner.body.delta
```

**Option B — prefix-detect (defensive):** works even if a future plugin version starts sending truly incremental chunks.
```
if (inner is text_delta):
    existing = stream_buffer[inner.id] or ""
    if inner.body.delta starts_with existing:
        stream_buffer[inner.id] = inner.body.delta   # cumulative
    else:
        stream_buffer[inner.id] = existing + inner.body.delta   # incremental fallback
```

The Swift reference client uses Option B. See `chat94/Sources/Views/ChatView.swift` in the `case .textDelta` branch.

### `text_end` is authoritative

`text_end.body.text` contains the full, final message. Always overwrite your displayed text with it when `text_end` arrives — never trust your accumulated deltas to be bit-for-bit correct. Redeliveries, packet loss, or future protocol tweaks can all cause your buffer to diverge; `text_end` corrects.

---

## 4a. `reset: true` on `text_end` — abandon, don't finalize

When `text_end.body.reset == true`, the stream is being **abandoned** — the plugin decided the in-progress reply should not appear in the chat at all. The receiver should:

1. Delete the bubble for that `stream_id`. Animate however the UI prefers (fade, collapse, slide).
2. Drop any accumulated buffer for that `stream_id`.
3. **Not** insert `text_end.body.text` as a finalized message.

If `reset` is missing or `false`, behavior is unchanged from §4 — finalize the stream with the authoritative text.

Backwards compat: clients that ignore `reset` will show the abandoned content as a normal final message. Not broken, just not deleted.

The Swift reference client tracks the streaming bubble's `UUID` against the current `stream_id` (`currentStreamMessageId` ↔ `currentStreamId`). On `reset: true`, it removes the message inside `withAnimation(.easeOut(duration: 0.2))`, deletes from SwiftData, clears stream tracking, and re-scrolls. See `cancelCurrentStreamingMessage(streamId:)` in `chat94/Sources/Views/ChatView.swift`.

---

## 5. Canonical timeline of a reply

The most common sequence, start to finish:

```
USER SENDS MESSAGE
      |
      v
status: typing        (pipeline wakes up)
status: thinking      (model starts reasoning)    -- may repeat many times
status: thinking
status: thinking
status: typing        (reasoning done, text begins)
text_delta { delta: "Hello" }          + status: typing
text_delta { delta: "Hello world" }    + status: typing
text_delta { delta: "Hello world!" }   + status: typing
text_end   { text:  "Hello world!" }
status: idle
```

### Variants

**Short reply, no streaming:**
```
status: typing
status: thinking
text   { text: "Hello world!" }       (complete reply, not streamed)
status: idle
```

**With tool use:**
```
status: typing
status: thinking
status: thinking                      (initial reasoning)
status: thinking                      (onToolStart fires)
  [tool executes]
status: thinking                      (next assistant turn begins, new reasoning)
status: typing                        (streaming starts)
text_delta ...
text_end
status: idle
```

Note: tool-use means `thinking` can re-enter **after** text has started, across multiple assistant-message cycles. Within a single message, OpenClaw does not interleave `thinking` and text. But if the agent uses a tool, the next message starts a new reasoning → text cycle. Clients must accept `thinking` arriving after previous text without surprise.

**Empty or errored reply:**
```
status: typing
status: idle         (no text emitted)
```

---

## 6. Reference implementation notes (Swift client)

What the Swift client does; pick these patterns or equivalents.

### 6.1 Single "busy" state, monotonic timer

Instead of separate `isThinking` and `isTyping` flags (which flicker as statuses flip), use **one** `isAgentBusy` boolean with a single `busyStartTime`.

- `isAgentBusy = true` on **user send** (not just on first incoming status — gives instant UI feedback).
- `busyStartTime` set **once** when busy begins; not touched on phase transitions.
- `busyPhase: String` — cosmetic label ("Thinking" vs "Typing") that can change freely.
- Clear busy **only** on `status:idle`, `text_end`, or a complete non-streamed `text` from the agent.

File: `chat94/Sources/Views/ChatView.swift`, in `ChatViewModel`.

### 6.2 Status handling

```
switch status:
    "thinking": mark busy, phase = "Thinking"        (skip write if already busy+phase)
    "typing":   if busy, phase = "Typing"            (do NOT clear busy, do NOT reset timer)
    "idle":     clear busy                           (skip write if not busy)
    default:    no-op                                (forward-compat)
```

The `if already = desired` skip is important on reactive/observable state (Swift `@Observable`, React state, SwiftUI bindings, etc.): the plugin fires `status:thinking` many times per reasoning phase, and writing the same value repeatedly causes layout thrash and, in the Swift client, actually caused a 99% CPU hang. Write only on real transitions.

### 6.3 Delta accumulation

One buffer per stream id. Prefix-match detection per §4 Option B. On `text_end`, overwrite with the authoritative `text_end.body.text`.

### 6.4 Message rendering

Track the streaming message by its **stream id**, not by "the last message in the list". If another message arrives mid-stream (e.g. an image from another device), appending to the tail creates orphaned duplicates.

In the Swift client this is currently done by convention (`messages.last` + `status == .sending`) but should be tightened if you hit edge cases.

### 6.5 UI layout — indicators inside the scroll view

The busy / remote-typing indicators should live **inside** the scroll view as flowing content, not as siblings that conditionally appear below it. If they're siblings, their appearance/disappearance resizes the scroll view and the content snaps visibly. Inside the scroll view, they flow with messages and the bottom stays the bottom.

File: `chat94/Sources/Views/ChatView.swift`, inside the `ScrollView { LazyVStack { ... } }`.

### 6.6 Scroll-to-bottom on new content

Do this cheaply, without animation. A plain `scrollTo(lastId, anchor: .bottom)` (no `withAnimation`) extends naturally when content is appended. Animated scrolls stack and feel like dragged motion.

Single trigger: on message count change. On initial view load, defer ~150ms to let lazy layout materialize, then scroll once.

---

## 7. Pitfalls checklist

Concrete mistakes to avoid:

1. **Treating `status:typing` as "stop thinking".** It is a per-chunk heartbeat during streaming. Only `idle` means "stop".
2. **Appending `text_delta.delta` to a buffer.** Deltas are cumulative. Replace the buffer (or use prefix-detection as a defensive shim).
3. **Trusting accumulated deltas over `text_end`.** When `text_end` arrives, overwrite with its `text` field.
4. **Resetting the busy timer on every status.** The timer should be monotonic — set once when busy begins, cleared once when busy ends. Status transitions do not reset it.
5. **Writing the same reactive value repeatedly.** Observable frameworks usually notify on every write regardless of whether the value changed. Guard writes with `if state != newState` to avoid UI thrash (and, in reactive-heavy stacks, real CPU hangs).
6. **Placing the busy indicator as a scroll-view sibling.** It resizes the scroll area on toggle and the content snaps. Put it inside the scroll content.
7. **Assuming no `thinking` after text.** Tool use re-enters thinking in the next message. Handle it.
8. **Animating scroll on every message.** Multiple animated scrolls stack (message count + busy state + streaming text growth) and feel like a UI losing fights with itself. Single instant snap on count change is enough.
9. **Not deduping on reconnect.** If the relay redelivers queued messages after a reconnect, a naive client will process the same deltas twice. Dedup by outer `msg_id` if your transport exposes it, or trust `text_end` to correct the drift.
10. **Assuming the stream id is stable across reconnects.** Don't. Track by stream id for the current session but expect new ids after a drop.

---

## 8. Minimum conformance requirements

A client that claims to support chat94 streaming must:

- Decode all four inner types (`text`, `text_delta`, `text_end`, `status`) without error.
- Tolerate unknown inner types and unknown `status` values.
- Handle cumulative `text_delta` correctly (see §4).
- Overwrite with `text_end.body.text` on stream completion.
- Distinguish `status: idle` from `status: typing` (the latter is not a terminator).
- Remain responsive under dozens of `status` messages per reply.

A client that claims good UX should additionally:

- Start the busy timer on user send, not on first inbound status.
- Keep the timer monotonic across status transitions.
- Render mid-stream text without flicker or scroll-thrash.
- Not re-enter or double-increment state on observed-write patterns.

---

## 9. File references

**Plugin (TypeScript, `chat94-plugin/`):**
- `src/channel.ts:417-419` — `deliver()` stream path: `lastText += text`, `sendStreamDelta(..., text)`
- `src/channel.ts:466-499` — all status emission sites
- `src/send.ts:128-129` — `sendStreamEnd(groupId, streamId, fullText)`
- `src/types.ts:126,137` — `InnerTextBody`, `InnerDeltaBody`
- `tests/unit/send.test.ts:76-94` — wire-format fixtures

**OpenClaw (TypeScript, `vendor/openclaw/`):**
- `src/auto-reply/reply/agent-runner-execution.ts:938` — `onPartialReply` invocation
- `src/auto-reply/reply/agent-runner-execution.ts:975` — `onToolStart` invocation (phase "start")
- `src/agents/pi-embedded-subscribe.ts:668` — `onReasoningStream` invocation
- `src/agents/pi-embedded-subscribe.handlers.messages.ts:79,89,268-285` — assistant message start, reasoning end, text_delta handler

**Swift reference client (`chat94/Sources/`):**
- `Gateway/WebSocketClient.swift` — `processInnerMessage` (stream buffer accumulation)
- `Gateway/ProtocolModels.swift` — `InnerMessage` type and JSON codec
- `Views/ChatView.swift` — `ChatViewModel` busy-state machine and `handleInnerMessage`
- `Views/ChatView.swift` — `busyIndicator` view and scroll handling

---

## 10. Changelog

- **2026-04-18** — initial doc. Captured cumulative-delta gotcha, single-busy-state pattern, and scroll/indicator layout lessons after the Swift client's first streaming-bug pass.
