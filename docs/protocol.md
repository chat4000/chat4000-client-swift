# chat4000 Relay Protocol Specification

Version: 1
Status: Draft
Last updated: 2026-04-25

---

## 1. Overview

chat4000 uses a central relay server to route end-to-end encrypted messages between app clients and OpenClaw plugins. The relay is zero-knowledge for chat traffic: it never sees plaintext chat content.

The pairing model in this version is:

1. A user group has one long-lived **group key** (`32` random bytes, `256` bits).
2. The OpenClaw plugin creates that group key once when the group is first bootstrapped.
3. The plugin also creates temporary **pairing codes** whenever it wants to link a new client.
4. Any already-paired client may later create another temporary pairing code to link an additional client, but it reuses the same existing group key.
5. Pairing codes are used only to find and confirm a temporary pairing session; they are never the permanent key.

The relay does not derive the group key and does not decide who should own it. It only:

- hosts temporary pairing rooms
- forwards opaque pairing frames
- routes encrypted chat traffic by `group_id`

---

## 2. Transport

- **Protocol**: WebSocket (RFC 6455) over TLS
- **URL**: `wss://relay.chat4000.com/ws`
- **Default port**: 443
- **Frame type**: JSON text frames
- **Encoding**: UTF-8
- **Max frame size**: 65,536 bytes

### Endpoints

| Path | Method | Description |
|------|--------|-------------|
| `/ws` | GET (upgrade) | WebSocket connection |
| `/health` | GET | Health check |

### Push Routing Metadata

When an app client supports APNs wake notifications, it should include its Apple app identifier
in `hello` so the relay knows which APNs topic to use for that device.

The relay should treat `app_id` as the APNs topic.

---

## 3. Long-Lived Key Model

Each pairing group has one shared symmetric key:

```text
group_key = random(32 bytes)
group_id  = lowercase_hex(SHA-256(group_key))
```

Properties:

- `group_key` is generated once
- `group_key` is reused forever by that group unless a future key-rotation feature is added
- every member computes the same `group_id` independently
- the relay only sees `group_id`, not `group_key`

### 3.1 Initial Creation

The plugin creates the group key locally when the group is first set up.

Bootstrap flow:

- plugin generates `group_key`
- plugin computes `group_id`
- plugin stores the key locally
- plugin opens pairing mode by generating a short pairing code
- first client joins with that pairing code and receives the existing key

In this protocol, the plugin is the default owner of first-key creation.

### 3.2 Subsequent Pairing

When adding another client:

- the initiator already has the existing `group_key`
- the initiator may be the plugin or any already-paired client
- the joiner receives that existing `group_key`
- no new permanent key is created

---

## 4. Pairing Code Model

The human-entered pairing code is temporary and separate from the permanent group key.

Recommended format:

- `XXXX-XXXX`
- uppercase
- single-use

Recommended alphabet:

```text
ABCDEFGHJKMNPRTUVWXYZ2346789
```

Excluded as ambiguous:

```text
0 O 1 I L 5 S
```

The pairing code is used to create a temporary room identifier:

```text
normalized_code = uppercase(remove_dashes(code))
room_id = hex(SHA-256("pairing-v1:" || normalized_code))
```

The relay routes by `room_id`. The relay does not derive the permanent group key from the code.

---

## 5. Pairing Protocol

### 5.1 Roles And Temporary Values

This pairing protocol has two parties:

- `initiator`: already has the permanent `group_key`
- `joiner`: wants to receive that permanent `group_key`

The initiator may be:

- the plugin during first bootstrap
- an already-paired client adding another client

The joiner creates a **temporary asymmetric keypair**:

```text
b       = temporary private key
B_pub   = temporary public key
```

The initiator creates only a temporary public random value:

```text
A_salt = temporary public random value
```

`B_pub` is the joiner's large public value. It serves two purposes:

1. proof input alongside the pairing code
2. encryption target for the permanent `group_key`

`A_salt` is only a public pairing nonce/value from the initiator. It does not need to be a long-lived identity key.

### 5.2 Relay Pairing Messages

| Type | Direction | Purpose |
|------|-----------|---------|
| `pair_open` | client -> relay | join or create temporary pairing room |
| `pair_open_ok` | relay -> client | room open acknowledged |
| `pair_ready` | relay -> both | one initiator and one joiner are present |
| `pair_data` | either direction via relay | opaque pairing payload |
| `pair_complete` | joiner -> relay | pairing succeeded |
| `pair_cancel` | either direction or relay | close room immediately |

No application-level error message is required after pairing has started. On any mismatch or local failure:

- cancel if practical
- otherwise disconnect
- relay tears the room down

### 5.3 Pairing Room Rules

For each `room_id`, the relay allows:

- at most one initiator
- at most one joiner
- exactly one active pairing attempt

The room is destroyed on:

- `pair_complete`
- `pair_cancel`
- initiator disconnect
- removal from relay memory after 7 days

The relay does not need to expose a visible countdown or expiry timestamp to clients.

### 5.4 Pairing Envelope Format

Every wire frame:

```json
{
  "version": 1,
  "type": "<message_type>",
  "payload": { ... }
}
```

---

## 6. Relay Registration And Push Metadata

After pairing, app clients register to the relay with `hello`.

### 6.1 App `hello`

```json
{
  "version": 1,
  "type": "hello",
  "payload": {
    "role": "app",
    "group_id": "<group_id>",
    "device_id": "<stable_app_device_id>",
    "device_token": "<apns_device_token>",
    "app_id": "com.neonnode.chat4000app.dev",
    "app_version": "1.2.3",
    "release_channel": "appstore"
  }
}
```

Rules:

- `device_id` is required for app clients
- `device_id` must be stable for that app install / device instance
- `device_token` is optional; if absent, the relay must not attempt APNs for that device
- `app_id` is optional; if absent, the relay must not attempt APNs for that device
- `app_version` should be sent on every app session `hello`
- `release_channel` should be sent on every app session `hello`
- `app_id` is the APNs topic and should match the app bundle identifier
- APNs environment should come from relay configuration, not the client payload
- if a device reconnects with a new token or push metadata, the relay should overwrite the stored record for that device connection

### 6.2 Offline Push Triggering

The relay should attempt push only when all of the following are true:

- message type is `msg`
- `payload.notify_if_offline == true`
- no app device is currently connected for that `group_id`
- the relay has a stored `device_token`
- the relay has a stored `app_id`

The relay should use:

- APNs device token = stored `device_token`
- APNs topic = stored `app_id`
- APNs host selected from relay configuration
- per-device app offline queue key = `group_id + device_id`
- app `hello` must drain only that app device's queue

### 6.3 `msg` Push Flag

Only real content messages should request offline push:

- `msg` -> may set `notify_if_offline: true`

The following must not request offline push:

- `status`
- `text_delta`
- `text_end`
- pairing traffic

Example:

```json
{
  "version": 1,
  "type": "msg",
  "payload": {
    "msg_id": "uuid",
    "nonce": "...",
    "ciphertext": "...",
    "notify_if_offline": true
  }
}
```

---

### 5.5 Pairing Flow

Names:

- `K` = permanent group key
- `CODE` = short pairing code
- `A_salt` = initiator public random value
- `b`, `B_pub` = joiner temporary private/public keypair

#### 1. Initiator opens pairing mode

The initiator already has `K`. It creates:

- `CODE`
- `A_salt`
- `room_id = H("pairing-v1:" || normalized_code)`

Typical cases:

- plugin initiates first-client bootstrap
- client initiates add-another-client pairing

It sends:

```json
{
  "version": 1,
  "type": "pair_open",
  "payload": {
    "role": "initiator",
    "room_id": "9c4b...f1"
  }
}
```

Relay replies:

```json
{
  "version": 1,
  "type": "pair_open_ok",
  "payload": {}
}
```

#### 2. Joiner enters the code

The joiner normalizes the code, derives the same `room_id`, and creates a temporary keypair:

```text
b, B_pub
```

It sends:

```json
{
  "version": 1,
  "type": "pair_open",
  "payload": {
    "role": "joiner",
    "room_id": "9c4b...f1"
  }
}
```

Relay then sends to both:

```json
{
  "version": 1,
  "type": "pair_ready",
  "payload": null
}
```

#### 3. Initiator sends its temporary public value

```json
{
  "version": 1,
  "type": "pair_data",
  "payload": {
    "t": "hello",
    "salt": "A_salt_base64"
  }
}
```

#### 4. Joiner sends its temporary public key

`B_pub` is sent in the field named `salt`. In this protocol, the joiner's salt is its public key.

```json
{
  "version": 1,
  "type": "pair_data",
  "payload": {
    "t": "join",
    "salt": "B_pub_base64"
  }
}
```

#### 5. Joiner proves it knows the same pairing code

The joiner computes:

```text
proof_b = H(normalized_code || A_salt || B_pub || "B")
```

It sends:

```json
{
  "version": 1,
  "type": "pair_data",
  "payload": {
    "t": "proof_b",
    "proof": "proof_b_base64"
  }
}
```

#### 6. Initiator verifies and sends the permanent key

The initiator verifies `proof_b`. If it does not match:

- it cancels or disconnects
- the room is destroyed

If it matches, the initiator computes:

```text
proof_a = H(normalized_code || A_salt || B_pub || "A")
wrapped_key = Enc(B_pub, K)
```

Then sends:

```json
{
  "version": 1,
  "type": "pair_data",
  "payload": {
    "t": "grant",
    "proof": "proof_a_base64",
    "wrapped_key": "ciphertext_base64"
  }
}
```

Notes:

- `wrapped_key` is the permanent group key encrypted directly to the joiner's temporary public key
- it is **not** encrypted to a symmetric key derived from the short code

### 5.5.1 Required Concrete Cryptographic Encoding

To remove implementation ambiguity, the following encoding is required for this protocol.

Binary values:

- `normalized_code_bytes` = UTF-8 bytes of the normalized pairing code
- `A_salt_raw` = decoded bytes of `A_salt_base64`
- `B_pub_raw` = decoded bytes of `B_pub_base64`
- `K` = 32-byte permanent group key

Hash function:

- `H` = SHA-256

Proof encoding:

```text
proof_b_raw = SHA-256(
  normalized_code_bytes || 0x00 || A_salt_raw || 0x00 || B_pub_raw || 0x00 || "B"
)

proof_a_raw = SHA-256(
  normalized_code_bytes || 0x00 || A_salt_raw || 0x00 || B_pub_raw || 0x00 || "A"
)
```

Wire format:

- `proof` fields are `base64(proof_*_raw)`

Wrapped key construction:

- `Enc(B_pub, K)` means X25519 key agreement plus XChaCha20-Poly1305
- the initiator generates an ephemeral X25519 sender keypair for the wrap operation
- derive a 32-byte wrapping key from the shared secret with:

```text
wrap_key = SHA-256(shared_secret || "chat4000-pair-wrap-v1")
```

- generate a random 24-byte nonce
- encrypt `K` with XChaCha20-Poly1305 using `wrap_key`
- encode `wrapped_key` on the wire as:

```json
{
  "ephemeral_pub": "base64(32-byte-x25519-public-key)",
  "nonce": "base64(24-byte-nonce)",
  "ciphertext": "base64(ciphertext||tag)"
}
```

That object is serialized as the value of `wrapped_key`.

This protocol requires exactly this construction so both relay and clients implement the same proof and wrapping behavior.

#### 7. Joiner verifies and stores the group key

The joiner:

1. verifies `proof_a`
2. decrypts `wrapped_key` using `b`
3. stores the resulting permanent `K`
4. computes `group_id = SHA-256(K)`

#### 8. Joiner confirms success

```json
{
  "version": 1,
  "type": "pair_complete",
  "payload": {
    "status": "ok"
  }
}
```

Relay destroys the room immediately.

### 5.6 Minimal Transcript Example

Example A: plugin pairs first client

```text
plugin(initiator) -> relay : pair_open(role=initiator, room_id)
relay -> plugin           : pair_open_ok

client(joiner) -> relay   : pair_open(role=joiner, room_id)
relay -> both             : pair_ready

plugin -> client          : pair_data { t:"hello", salt:A_salt }
client -> plugin          : pair_data { t:"join", salt:B_pub }
client -> plugin          : pair_data { t:"proof_b", proof:... }
plugin -> client          : pair_data { t:"grant", proof:..., wrapped_key:... }
client -> relay           : pair_complete
relay closes room
```

Example B: paired client adds another client

```text
client_A(initiator) -> relay : pair_open(role=initiator, room_id)
relay -> client_A            : pair_open_ok

client_B(joiner) -> relay    : pair_open(role=joiner, room_id)
relay -> both                : pair_ready

client_A -> client_B         : pair_data { t:"hello", salt:A_salt }
client_B -> client_A         : pair_data { t:"join", salt:B_pub }
client_B -> client_A         : pair_data { t:"proof_b", proof:... }
client_A -> client_B         : pair_data { t:"grant", proof:..., wrapped_key:... }
client_B -> relay            : pair_complete
relay closes room
```

### 5.7 Cancel Behavior

If anything goes wrong, either side should stop immediately.

Preferred wire message:

```json
{
  "version": 1,
  "type": "pair_cancel",
  "payload": {
    "reason": "cancelled"
  }
}
```

But this message is optional. A disconnect is enough. The relay must destroy the room in either case.

Failure examples:

- initiator closes pairing UI
- joiner closes pairing UI
- proof mismatch
- timeout
- duplicate peer
- local crypto failure

Behavior:

- do not continue
- do not retry inside the same room
- tear down and return to idle state

---

## 6. Session Protocol

### 6.1 Overview

After the joiner receives `K`, both sides use the permanent group key exactly as before.

### 6.2 Session Messages

The normal relay session uses:

- `hello`
- `hello_ok`
- `hello_error`
- `msg`
- `ping`
- `pong`

### 6.3 Hello Handshake

```json
{
  "version": 1,
  "type": "hello",
  "payload": {
    "role": "app",
    "group_id": "64-char-lowercase-hex",
    "device_id": "stable-app-device-id",
    "device_token": "optional-apns-token",
    "app_id": "com.neonnode.chat4000app.dev",
    "app_version": "1.2.3",
    "release_channel": "appstore",
    "last_acked_seq": 4123
  }
}
```

Or:

```json
{
  "version": 1,
  "type": "hello",
  "payload": {
    "role": "plugin",
    "group_id": "64-char-lowercase-hex",
    "app_version": "1.2.3",
    "release_channel": "dev",
    "last_acked_seq": 871
  }
}
```

Rules:

- app clients must send `device_id` on every `hello`
- the relay uses `device_id` for per-device offline queueing
- `app_version` is optional at the protocol level but should be sent by all normal clients and plugins
- `release_channel` is optional at the protocol level but should be sent by all normal clients and plugins
- the relay may use these values for analytics, minimum-version enforcement, and operational debugging
- the relay returns the current Terms version in `hello_ok`
- `last_acked_seq` is the highest relay-assigned `seq` (see §6.4 and §6.6) that the client has stably persisted; on reconnect the relay must redrive every queued message with `seq > last_acked_seq` for that `(group_id, role, device_id)` pair before delivering any new messages
- `last_acked_seq` is optional; if absent or `0`, ack-aware relays redrive the entire current queue, and pre-ack relays/clients fall back to the legacy fan-out-then-evict behavior described in §6.6

Responses:

```json
{
  "version": 1,
  "type": "hello_ok",
  "payload": {
    "current_terms_version": 200,
    "version_policy": {
      "min_version": "1.0.0",
      "recommended_version": "1.2.0",
      "latest_version": "1.3.0"
    },
    "plugin_version_policy": {
      "min_version": "0.5.0",
      "recommended_version": "0.7.0",
      "latest_version": "0.8.1"
    }
  }
}
```

`version_policy` is purely informational. The relay does not disconnect, does not enforce, and does not include `upgrade_required` / `upgrade_recommended` booleans. All upgrade-prompt logic lives in the client.

Resolution rules on the relay:

- the relay looks up `hello.app_id` in a flat config map
- if the entry exists, it echoes the three string fields
- if `app_id` is missing or has no entry, `version_policy` is omitted entirely
- all three inner fields are individually optional (any can be `null` or absent)

Client behavior (informational; required for any client that ships a UI):

- parse `payload.version_policy` after `hello_ok`; treat the object and each of `min_version` / `recommended_version` / `latest_version` as independently optional
- compare locally with semver
  - if `min_version` is set and `app_version < min_version` → hard block (non-dismissible "update required" UI; do not allow further chat)
  - else if `recommended_version` is set and `app_version < recommended_version` → soft nag (dismissible "update available" banner)
  - else → no UI
  - `latest_version` is informational only
- if `app_version` is missing or unparseable → behave as if `recommended_version` was crossed (soft nag), never hard-block
- re-evaluate on every reconnect; do not cache as authoritative across launches

If the policy is omitted entirely, behavior is unchanged (legacy clients keep working).

#### Plugin Version Policy

`plugin_version_policy` is the same shape as `version_policy` but applies to the plugin running on the user's paired computer rather than to the app itself. It allows the relay operator to flag outdated OpenClaw plugin builds without ever inspecting the plugin's traffic.

Resolution rules on the relay:

- the relay looks up the plugin policy by **plugin bundle id** (the same value that plugin-emitted inner messages carry as `from.bundle_id`, e.g. `@chat4000/openclaw-plugin`)
- the resolved plugin bundle id may be configured per-`app_id` (so different apps can target different plugin packages) or as a single relay-wide default; relay implementations choose one
- **the relay must never use default version values**; every field of every echoed `plugin_version_policy` must come from explicit relay config
- if the relay has no configured plugin policy entry for the resolved plugin bundle id, `plugin_version_policy` is **omitted entirely** from `hello_ok`
- all three inner fields (`min_version`, `recommended_version`, `latest_version`) are individually optional inside the config; fields not present in config are omitted from the wire shape
- the relay never reads or trusts the plugin's actual running version; it only echoes config — the plugin's running version reaches the client only through encrypted inner messages

Client behavior (informational; required for any client that ships a UI):

- parse `payload.plugin_version_policy` after `hello_ok` exactly like `version_policy` — treat the object and each of `min_version` / `recommended_version` / `latest_version` as independently optional
- the plugin version the client compares against is observed from inner messages with `from.role == "plugin"`, specifically `from.app_version`; until at least one plugin inner message arrives, the client has no version to compare and shows no UI
- compare locally with semver:
  - if `min_version` is set and `plugin_version < min_version` → hard block (non-dismissible "your paired computer is running an outdated plugin; update OpenClaw to continue"; do not allow further chat)
  - else if `recommended_version` is set and `plugin_version < recommended_version` → soft nag (dismissible "plugin update available" banner)
  - else → no UI
  - `latest_version` is informational only
- if the plugin's `from.app_version` is missing or unparseable → behave as if `recommended_version` was crossed (soft nag), never hard-block
- re-evaluate on every plugin inner message and on every reconnect; do not cache as authoritative across launches
- if multiple plugins exist in the same group, evaluate each plugin's version against the same policy and apply the worst-case status (hard-block dominates soft-nag)

If `plugin_version_policy` is omitted entirely, behavior is unchanged (legacy apps and unconfigured relays keep working).

```json
{
  "version": 1,
  "type": "hello_error",
  "payload": {
    "code": "KEY_NOT_REGISTERED",
    "message": "No peer has registered this group key"
  }
}
```

### 6.4 Encrypted Chat Message

Sender → relay form (no `seq`; the relay assigns one on fan-out):

```json
{
  "version": 1,
  "type": "msg",
  "payload": {
    "nonce": "24-byte-base64",
    "ciphertext": "base64(ciphertext||tag)",
    "msg_id": "uuid",
    "notify_if_offline": true
  }
}
```

Relay → recipient form (relay-assigned `seq` added on the outbound copy):

```json
{
  "version": 1,
  "type": "msg",
  "payload": {
    "nonce": "24-byte-base64",
    "ciphertext": "base64(ciphertext||tag)",
    "msg_id": "uuid",
    "notify_if_offline": true,
    "seq": 4124
  }
}
```

Encryption:

- algorithm: XChaCha20-Poly1305
- key: permanent `group_key`
- nonce: 24 random bytes

Relay-visible metadata:

- `notify_if_offline`: optional boolean
- `seq`: relay-assigned monotonic sequence number, scoped to a single recipient `(group_id, role, device_id)` triple; see §6.6 for full semantics

Rules:

- `notify_if_offline` is on the outer relay `msg.payload`, not inside encrypted inner content
- it is intended for notification-worthy content only
- senders should set it for plugin-sent:
  - `text`
  - `image`
- senders should not set it for:
  - `status`
  - `text_delta`
  - `text_end`
  - pairing traffic
- if `notify_if_offline == true` and no app device is currently connected for the `group_id`, the relay should send push notifications to all registered devices for that group
- offline delivery for apps is per registered `device_id`, not one shared group queue
- senders must not set `seq`; the relay assigns it independently for each recipient and rewrites the outbound payload accordingly
- recipients use `seq` exclusively for acknowledgement and offline-queue replay; ordering of message rendering still follows wall-clock `ts` and the streaming rules in §6.4.2

### 6.4.0 Offline Queue Semantics

- plugin -> apps:
  - relay assigns a per-recipient `seq` for each connected and each registered-but-offline app `device_id`
  - relay sends the message to connected app devices with that recipient's `seq` filled in
  - relay also stores the encrypted `msg` (with the assigned `seq`) in a durable per-recipient queue keyed by `(group_id, role=app, device_id)`
- app -> plugin:
  - relay assigns a per-recipient `seq` for the plugin and for each other registered app device in the group
  - relay sends the message to the plugin if connected, with the plugin's `seq` filled in
  - relay otherwise stores the encrypted `msg` in the durable plugin queue keyed by `(group_id, role=plugin)`
  - relay also fans out to every other connected app device with that recipient's `seq` and stores it in each offline app device's queue
- on `hello` (any role):
  - relay drains only the queue for that connection's `(group_id, role, device_id)` triple
  - relay must not drain one shared group queue for all app devices
  - if `hello.last_acked_seq` is present, the relay redrives only entries with `seq > last_acked_seq` and discards lower entries from the queue
  - if `hello.last_acked_seq` is absent or `0`, the relay redrives every entry currently in that recipient's queue
- queue eviction: ack-driven; see §6.6 for the authoritative eviction rules. Pre-ack legacy clients still trigger optimistic eviction at fan-out time, but ack-aware clients must be served by ack-driven retention.
- queue durability: per §8, the relay queue must survive process restarts

### 6.4.1 Encrypted Inner Message Metadata

The plaintext JSON carried inside a `msg` frame may include sender metadata:

```json
{
  "t": "text",
  "id": "uuid",
  "from": {
    "role": "app",
    "device_id": "stable-device-id",
    "device_name": "User's iPhone",
    "app_version": "1.0.0",
    "bundle_id": "com.neonnode.chat4000app"
  },
  "body": {
    "text": "hello"
  },
  "ts": 1710000000000
}
```

Rules:

- `from` is optional for backward compatibility
- `from.role` is one of:
  - `app`
  - `plugin`
- `from.device_id` should be stable for that sender instance
- `from.device_name` should be human-readable
- `from.app_version` should be the app/plugin version for that sender instance
- `from.bundle_id` should be the app bundle identifier or plugin package name
- implementations that parse and re-emit inner messages must preserve `from`
- receivers must not fail if `from.app_version` or `from.bundle_id` is missing

Rendering semantics:

- `from.role == "app"`: render as a user-side message
- `from.role == "plugin"`: render as a plugin/agent-side message
- clients may ignore same-device echoes by matching local `device_id`

### 6.4.2 Streaming Rules

Streaming inner message types:

- `text_delta`
- `text_end`

`text_delta` body:

```json
{
  "t": "text_delta",
  "id": "frame-uuid",
  "body": {
    "delta": " world",
    "stream_id": "stream-uuid"
  },
  "ts": 1710000000000
}
```

`text_end` body:

```json
{
  "t": "text_end",
  "id": "frame-uuid",
  "body": {
    "text": "Hello world",
    "reset": false,
    "stream_id": "stream-uuid"
  },
  "ts": 1710000000000
}
```

Rules:

- each `text_delta` and `text_end` frame has its own unique inner `id` — a fresh UUID per frame, just like every other inner type. Inner `id` is the logical-msg id and is dedup-able per §6.6.9.
- the **stream correlator** lives in `body.stream_id` and is shared across every frame belonging to one logical streaming reply
- within a single `stream_id`, `text_delta.body.delta` is append-only
- receivers must concatenate deltas in arrival order for that `stream_id`
- `text_end` finalizes that same `stream_id`
- senders must not use later `text_delta` frames in the same `stream_id` to rewrite or replace earlier text

Backwards-compat (transitional): receivers SHOULD prefer `body.stream_id` and fall back to inner `id` when `body.stream_id` is absent. This lets new clients render correctly against pre-spec senders that still reuse `inner.id == stream_id`. New senders MUST emit `body.stream_id`. The fallback path is removed once all known senders are upgraded.

`reset` is an optional boolean on `text_end`:

- `reset == true` → receiver should delete the bubble for that `stream_id` (the stream is being abandoned, not finalized). Animate the removal however the UI prefers.
- `reset == false` or absent → normal end-of-stream; finalize as the authoritative text.

Backwards compat: clients that ignore `reset` show the abandoned content as a normal final message — not broken, just not deleted.

If a sender rewrites, clears, or restarts the partial text instead of appending:

1. end the old stream
2. create a new `stream_id`
3. resume streaming on the new `stream_id`

Client behavior:

- if a new `stream_id` appears while another stream is still visible, treat it as a stream restart/reset and switch rendering to the new stream
- clients should not assume `text_delta` can patch arbitrary earlier text in-place

### 6.5 Keepalive and Encrypted Status

Relay-level `typing` and `typing_stop` are deleted.

Clients must not send:

```json
{ "version": 1, "type": "typing", "payload": {} }
{ "version": 1, "type": "typing_stop", "payload": {} }
```

If the app or plugin wants to show activity, it must send an encrypted inner
`status` message inside `msg.payload.ciphertext`, for example `typing` or
`idle`.

Keepalive remains:

```json
{ "version": 1, "type": "ping", "payload": null }
{ "version": 1, "type": "pong", "payload": null }
```

Application-layer keepalive rules:

- `ping` and `pong` are application-layer frames (not WebSocket protocol-level pings); they prove the receiving side's app process is actively pumping its receive loop, not just that the kernel TCP stack is alive
- a connected client (app or plugin) should send `ping` no less often than every `25 seconds` of socket-idle time
- the relay must reply to every `ping` with a `pong` on the same connection
- the relay must send a `ping` if it has not received any frame from the client for `60 seconds`; if no `pong` arrives within `15 seconds` of that relay-initiated `ping`, the relay closes the connection but **must not** evict that connection's per-device queue (see §6.6)
- clients may use a missed `pong` as a signal to drop and re-establish the WebSocket connection
- application-layer `ping`/`pong` are exempt from the offline queue and never carry `seq`

---

### 6.6 Reliable Delivery (Acknowledgements and Ticks)

This section is normative. It defines the acknowledgement layer that protects against silent message loss when a TCP socket dies between "bytes written by sender" and "bytes processed by receiver application".

#### 6.6.1 Failure Model

Two observed failure classes motivate this section. Implementations must assume both can happen:

- A receiver's TCP socket appears alive (kernel ACKs flowing) while the receiving app process is suspended (macOS App Nap, iOS background, plugin host swapping). The relay writes frames into the kernel receive buffer; the app never reads them; on connection reset the kernel discards the buffer; the frames are silently lost.
- A receiver opens a connection, the relay immediately fan-out-writes a large backlog, the receiver closes the socket within milliseconds (e.g. iOS re-backgrounds the app on launch). Bytes still in flight or in the kernel receive buffer are lost on close.

In both cases TCP guarantees byte transport from kernel to kernel, not application to application. The acknowledgement layer closes that gap.

#### 6.6.2 Two Ack Flows

There are two distinct ack flows. Implementations must support both.

- **Flow A — Persistence ack (outer, hop-by-hop, plaintext):** the receiver tells the relay "I have stably persisted the message identified by `seq` to my local durable store". The relay uses this to evict messages from the per-recipient queue. Carried in an outer `recv_ack` frame outside the encrypted envelope so that the relay can act on it.
- **Flow B — Processed ack (inner, end-to-end, encrypted):** the plugin tells the originating app "I have decrypted and accepted your prompt at the application layer". Carried as an inner message of `t == "ack"` inside the encrypted envelope so that the relay cannot forge or read it. Used to drive UI delivery indicators.

Flow A and Flow B are independent — a message may be Flow-A-acked by the recipient and never Flow-B-acked by the plugin, or vice versa. Implementations must track them separately.

#### 6.6.3 Outer `recv_ack` Frame (Flow A)

Sent from a receiving client (app or plugin) to the relay over the same WebSocket. Plaintext. Cumulative with optional selective ranges (TCP/QUIC-style):

```json
{
  "version": 1,
  "type": "recv_ack",
  "payload": {
    "up_to_seq": 4180,
    "ranges": [[4182, 4191]]
  }
}
```

Field rules:

- `up_to_seq`: the highest `seq` for which **every** lower seq has also been persisted. Cumulative high-water mark.
- `ranges`: optional array of `[low, high]` inclusive pairs identifying additional persisted seqs above `up_to_seq` that arrived out of order. Each pair must satisfy `low > up_to_seq` and `low <= high`. The relay may treat the ranges as advisory and either evict them or wait for them to be folded into the cumulative high-water mark.
- `ranges` should remain bounded; senders should keep at most 32 ranges and must keep at most 256

Sender obligations (the receiving client):

- emit `recv_ack` only **after** the inner message has been decoded and stably persisted to local durable storage (e.g. SwiftData's `ModelContext.save()` has returned)
- batch acks: emit a `recv_ack` when **any** of these conditions becomes true, whichever first
  - 32 newly persisted seqs are pending acknowledgement
  - 50 milliseconds have elapsed since the most recent persistence
  - the application is about to suspend, background, or close the WebSocket cleanly (final flush)
  - on receipt of a duplicate seq (re-emit the same cumulative high-water mark idempotently)
- never emit `recv_ack` for a seq the receiver has not durably persisted; doing so re-introduces the silent-loss bug

Relay obligations on receipt:

- advance per-recipient `last_acked_seq` to `max(current, payload.up_to_seq)`
- evict every queued entry with `seq <= last_acked_seq`
- additionally evict any queued entry whose `seq` falls inside any of `payload.ranges`
- never evict on any other signal — fan-out write does not evict, ws.close does not evict, idle_ping kill does not evict
- duplicate `recv_ack` for already-evicted seqs is a no-op

#### 6.6.4 Outer `relay_recv_ack` Frame (sender → relay → sender, optional v1)

Sent from the relay back to the originating client to confirm the relay accepted, queued, and fanned out an outbound message. Plaintext, outside the envelope:

```json
{
  "version": 1,
  "type": "relay_recv_ack",
  "payload": {
    "msg_id": "uuid",
    "queued_for": ["app:device-id-A", "plugin"]
  }
}
```

- `msg_id` echoes the inner `msg_id` of the originating message
- `queued_for` lists the recipient identities for which the relay assigned a `seq` and either delivered live or stored in a durable queue

This frame drives the "sent" tick in the originating client's UI. It is optional in v1 — clients must not depend on it for correctness, only as a UI hint. Pre-ack relays may omit it entirely.

#### 6.6.5 Inner `ack` Type (Flow B, end-to-end)

Sent inside the encrypted envelope. The relay cannot read or forge it. Used to render plugin-side delivery indicators in the originating app's UI.

```json
{
  "t": "ack",
  "id": "uuid-of-this-ack",
  "from": {
    "role": "plugin",
    "device_id": "...",
    "device_name": "...",
    "app_version": "0.7.2",
    "bundle_id": "@chat4000/openclaw-plugin"
  },
  "body": {
    "refs": "uuid-of-the-message-being-acked",
    "stage": "received"
  },
  "ts": 1710000000000
}
```

Field rules on `body`:

- `refs`: required; the inner `msg_id` of the message being acknowledged
- `stage`: required; one of:
  - `received` — the receiving party decrypted and accepted the message at the application layer
  - `processing` — the receiving party has handed the prompt to its agent runtime (optional; v1 implementations may skip and rely on subsequent `text_delta` as the "agent typing" signal)
  - `displayed` — the receiving party has shown the message to a human user (optional; reserved for human-to-human use; not required for plugin acks)

Sender obligations:

- emit a `received` ack as soon as the inner message has been decrypted and the body has been parsed without error; do not wait for downstream agent processing
- emit at most one `ack` of each `stage` per `refs`; duplicate `ack` frames for the same `(refs, stage)` are a no-op for the receiver
- senders must not include `ack` frames in offline queues semantically distinct from regular messages; they ride through the same encrypted-envelope path and inherit Flow A semantics for transport reliability

Receiver obligations:

- match `body.refs` to a locally-tracked outbound message and update its delivery state (see §6.6.7)
- ignore unknown values of `body.stage`

Sender restriction in v1 (multi-device groups):

- in v1 only the **plugin** emits inner `ack` frames. Apps do **not** emit inner `ack` frames for messages received from other apps. A multi-app-device group will therefore **not** show a "delivered to other app device" tick in v1; the "delivered" tick reflects exclusively that the plugin received the prompt
- a future protocol minor revision may relax this; until then, app implementations must omit the inner `ack` emission path for inbound `from.role == "app"` messages

#### 6.6.6 Sliding Window and Flow Control

To prevent unbounded relay-side buffering when a client is genuinely behind, the relay applies per-recipient flow control:

- the relay maintains a per-recipient unacked window with a default size of `64` queued entries (`seq` values) above the recipient's current `last_acked_seq`
- while the window is full, the relay must continue to enqueue inbound messages for that recipient durably, but must pause live fan-out writes to that recipient's socket (if connected)
- when an incoming `recv_ack` advances `last_acked_seq` and frees window slots, the relay resumes live fan-out for that recipient
- the relay should impose a hard upper bound on per-recipient queue depth (suggested: `10000` entries); above this bound, the relay may drop the oldest entries and surface this as an out-of-band operational alert; clients that hit this bound have effectively missed a chunk of history and the implementation should expose that fact to the user

#### 6.6.7 Delivery Status (Ticks)

UI-level meaning of each delivery state, in the originating client's view of an outbound message:

| Tick state | Trigger                                                                | Source of truth | Frame                 | Layer            |
|------------|------------------------------------------------------------------------|-----------------|-----------------------|------------------|
| sending    | message created locally, not yet acknowledged by the relay             | local           | none                  | local            |
| sent       | relay accepted, queued, and fanned out the outbound message            | relay           | `relay_recv_ack`      | **transport**    |
| delivered  | every recipient client and/or the plugin has decrypted the message     | recipient       | inner `ack` (stage=received) | **application** |
| failed     | message could not be sent (relay never reached, or network error)      | local           | none                  | local            |

The `sent` and `delivered` ticks are produced by **two different layers** and **must not be conflated**:

- **`sent` is a transport-layer event.** It originates from `relay_recv_ack`, which lives outside the encrypted envelope. The relay is its source of truth, and a reference client's `MessageTransport` (see §6.6.11) emits this signal automatically as part of its outbound-msg state machine.
- **`delivered` is an application-layer event.** It originates from an inner `ack` message with `t == "ack"`, which lives inside the encrypted envelope. The plugin (or another peer at the application layer) is its source of truth. The transport layer surfaces this purely as a regular received inner message — the consumer (e.g. ChatViewModel) is responsible for interpreting `inner.t == "ack"` and updating the matching outbound row's status.

Rendering rules:

- `sending` is the initial state for any user-originated outbound message
- on receipt of `relay_recv_ack` for the message, transition to `sent` (transport-layer signal)
- on receipt of an inner `ack` with `stage == "received"` and `refs == this message's msg_id` from a peer where `from.role == "plugin"`, transition to `delivered` (application-layer signal)
- in v1 the "delivered" tick is driven **exclusively by plugin acks**. Inner `ack` frames from `from.role == "app"` (other app devices in the same multi-device group) must be ignored for tick rendering, and apps must not emit such acks (see §6.6.5). A future protocol minor revision may add app-to-app delivery indicators
- the `processing` and `displayed` stages are optional in v1; first-token streaming via `text_delta` is the canonical signal that an agent has begun replying, and is sufficient for v1 UIs without a dedicated "agent typing" tick
- `failed` is set locally only after a client-side timeout or socket error; the protocol does not define a relay-emitted `relay_send_error` frame in v1

#### 6.6.8 Reconnect and Replay

On reconnect:

- the connecting party sends `hello` with `last_acked_seq` set to the highest `seq` it has stably persisted for the prior session of the same `(group_id, role, device_id)` triple
- the relay redrives every queued message with `seq > hello.last_acked_seq` for that recipient before delivering any newly arrived messages
- redriven messages keep their original `seq`; the relay does not re-assign sequence numbers on replay
- the originating sender of any redriven message is **not** notified of the redrive; the redrive is invisible to the original sender unless and until a fresh inner `ack` arrives back through the envelope

#### 6.6.9 Idempotency

- inner `msg_id` is the canonical identifier for application-layer deduplication, applied uniformly across all inner types — including `text_delta` and `text_end`, since every streaming frame carries its own fresh inner `id` (the stream correlator now lives in `body.stream_id`, see §6.4.2)
- recipients must dedupe by `msg_id`; a duplicate `msg_id` from any source must be processed exactly once at the application layer and its `seq` must still be acknowledged
- the relay must not modify or rewrite `msg_id` between fan-out copies; only the outer `seq` differs per recipient

#### 6.6.10 Backwards Compatibility

- pre-ack clients (no `last_acked_seq` in `hello`, no emission of `recv_ack`) interoperate with ack-aware relays; the relay falls back to legacy fan-out-then-evict behavior for those connections, accepting the legacy silent-loss risk
- pre-ack relays (no `seq` on outbound `msg.payload`, no acceptance of `recv_ack`) interoperate with ack-aware clients; clients treat absent `seq` as "ack layer disabled, do not emit `recv_ack`, transition `sent` based on best-effort local timeout, and skip `delivered` rendering entirely"
- the `version` field on the outer envelope remains `1`; the ack layer is purely additive

#### 6.6.11 Reference Client Architecture (informative)

The protocol prescribes the wire format. Implementations are free to structure their internals however they like, but reference clients on every supported language (Swift, Rust, TypeScript) should expose a uniform **`MessageTransport`** facade so that downstream code (chat UI, agent runner, CLI command) does not need to know about WebSockets, encryption, the ack layer, dedup, or reconnect logic. Two reasons:

> **Scope: session-time messaging only.** `MessageTransport` covers everything that happens AFTER pairing has produced a stable group key — `msg`, `recv_ack`, `relay_recv_ack`, `ping`/`pong`, hello/handshake using the established `group_id`, the §6.6 ack flow, dedup, reconnect, redrive. **Pairing is explicitly NOT in scope** and must remain a separate module (`PairingService` / `pairing.ts` / equivalent). Pairing is a one-shot bootstrap that runs BEFORE the group key exists, uses a different frame family (`pair_open`, `pair_open_ok`, `pair_ready`, `pair_data`, `pair_complete`, `pair_cancel`), routes by `room_id` not `group_id`, has no `seq`, no `last_acked_seq`, no idempotency table, no streaming, no encryption with the group key — none of `MessageTransport`'s machinery applies. A `MessageTransport` instance must only be constructed after pairing has succeeded and a group key is available. If a future protocol amendment makes pairing reuse the session connection, revisit this scope.

- swappable implementations (today's `seq` + cumulative `recv_ack` scheme, or a simpler per-msg-ack-with-retry scheme, or any future scheme) without touching consumers
- testable in isolation — a mock transport can drive consumers in unit tests without a real relay

The recommended interface, in language-agnostic terms:

```
MessageTransport {

  // Fire-and-forget. Returns the wire-level inner.id immediately.
  // The transport handles encryption, outbox, retries, and reconnects.
  send(msg: OutboundMessage) -> string  // inner.id

  // Inbound delivery. Called once per inner message,
  // GUARANTEED:
  //   - exactly once per inner.id (transport deduplicates)
  //   - in the sender's send order across reconnects (transport replays in order)
  //   - already decrypted to a typed InnerMessage
  // Note: inner messages of t == "ack" are surfaced through this callback
  //       like any other inner message; the transport does not interpret them.
  //       The consumer is responsible for updating "delivered" tick state when
  //       it sees an inner ack matching one of its outbound msg_ids.
  on_receive: (InnerMessage) -> void

  // Per-msg outbound status updates derived from transport-layer signals only.
  // Currently emits only:
  //   .sent  (on relay_recv_ack matching the outbound msg_id)
  //   .failed (on local timeout / socket error)
  // The "delivered" state is NOT emitted here; it is an application-layer
  // event derived from an inner ack and is the consumer's responsibility.
  on_status: (msg_id, .sent | .failed) -> void

  // Coarse connection state for UI and operational instrumentation.
  on_connection_state: (.disconnected | .connecting | .connected | .failed) -> void

  connect(group_config)
  disconnect()
}
```

Behaviour expected of any conformant transport:

- encryption with `group_key` and outer envelope wrapping happen inside `send`; consumers pass `OutboundMessage` (text/image/audio/textDelta/textEnd/status/ack), not `InnerMessage`
- the inner `ack` frame is a regular `OutboundMessage` variant; the transport emits it on the wire like any other inner type. The transport itself does not synthesize inner acks
- `on_receive` fires for **every** inner message including `t == "ack"`, after dedup by `inner.id` and in-order delivery guarantees. The transport must not silently swallow inner acks
- `on_status` only emits transport-layer states. The transport must not infer "delivered" from anything; that determination belongs to the consumer
- the transport owns: the WebSocket lifecycle, hello/handshake, heartbeat/ping-pong, durable outbox (or `seq`+`recv_ack` machinery), dedup table, reconnect/replay logic, App Nap / background-suspend countermeasures
- the transport does not own: chat history persistence, tick UI, agent runner integration, telemetry of business events

This separation is what allows the transport implementation to evolve (e.g. drop `seq` and adopt a per-msg-ack-with-retry scheme) without breaking consumers. It also gives every implementing language (Swift, Rust, TypeScript) the same conceptual surface area, even though the wire protocol is the only thing that's strictly normative.

---

## 7. Push Notifications

Push remains unchanged from the chat protocol:

1. app includes APNs token in `hello`
2. relay stores latest token for the `group_id`
3. if app is offline and plugin sends a message, relay queues encrypted message
4. relay sends a silent APNs push
5. app reconnects and drains queued messages

Push notification payload contains no plaintext chat message.

---

## 8. Storage Semantics

`group_key` is the long-lived private secret for the group.

Protocol requirements:

- pairing codes are temporary and must not become the permanent secret
- implementations must persist the long-lived `group_key` somewhere durable after successful pairing
- clients and plugins may choose different local storage mechanisms
- storage location, file format, and host integration are implementation details outside this protocol

This specification defines what value must survive pairing, not where a specific implementation stores it.

### 8.1 Relay Queue Durability

The per-recipient offline queue defined in §6.4.0 and §6.6 must be durable across relay process restarts. Implementations:

- must persist each enqueued message to non-volatile storage before considering the message accepted (e.g. SQLite with `synchronous=FULL` per-write, or equivalent fsync-on-commit semantics)
- must persist `last_acked_seq` per `(group_id, role, device_id)` triple alongside the queue
- must restore both queue contents and `last_acked_seq` on restart before accepting any new connections
- may compact or vacuum the queue on a coarse schedule but must not evict entries on any signal other than ack receipt or the queue-depth hard cap from §6.6.6

Without queue durability, the ack layer in §6.6 cannot deliver its correctness guarantee — a single relay restart would silently lose every message in the queue. Durability is therefore a normative protocol requirement, not an implementation detail.

## 9. Security Notes

This protocol intentionally makes the joiner's temporary public key (`B_pub`) do two jobs:

1. it participates in proof input with the short pairing code
2. it is the direct encryption target for the permanent group key

The relay sees:

- `room_id`
- `A_salt`
- `B_pub`
- proof fields
- wrapped permanent key

The relay does **not** learn `K` unless the underlying proof or wrapping construction is weak enough to permit an offline attack against the short pairing code.

That means the concrete proof and encryption primitives chosen for implementation matter. The transcript shape above is the protocol contract; the final cryptographic construction must be selected carefully during implementation.

---

## 10. Room And Rate-Limit Requirements

Minimum relay rules:

- pairing rooms should be dropped from live memory after `7 days`
- relay-level cleanup may continue to run on a coarser interval such as hourly
- max one initiator per room
- max one joiner per room
- destroy room on initiator disconnect
- destroy room on `pair_complete`
- destroy room on `pair_cancel`
- reject duplicate opens for occupied room roles
- rate-limit room creation and join attempts per IP

The relay should not try to recover a failed room. The safe behavior is to destroy it.
