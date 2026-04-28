# chat94 Relay Protocol Specification

Version: 1
Status: Draft
Last updated: 2026-04-25

---

## 1. Overview

chat94 uses a central relay server to route end-to-end encrypted messages between app clients and OpenClaw plugins. The relay is zero-knowledge for chat traffic: it never sees plaintext chat content.

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
- **URL**: `wss://relay.chat94.com/ws`
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
    "app_id": "com.neonnode.chat94app.dev",
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
wrap_key = SHA-256(shared_secret || "chat94-pair-wrap-v1")
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
    "app_id": "com.neonnode.chat94app.dev",
    "app_version": "1.2.3",
    "release_channel": "appstore"
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
    "release_channel": "dev"
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

Responses:

```json
{
  "version": 1,
  "type": "hello_ok",
  "payload": {
    "current_terms_version": 200
  }
}
```

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

Encryption:

- algorithm: XChaCha20-Poly1305
- key: permanent `group_key`
- nonce: 24 random bytes

Relay-visible metadata:

- `notify_if_offline`: optional boolean

Rules:

- this field is on the outer relay `msg.payload`, not inside encrypted inner content
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

### 6.4.0 Offline Queue Semantics

- plugin -> apps:
  - relay sends to connected app devices
  - relay queues the same encrypted `msg` for every registered app `device_id` that is not currently connected
- app -> plugin:
  - relay sends to plugin if connected
  - otherwise relay queues for plugin by `group_id`
  - relay fans out to other connected app devices
  - relay also queues for other registered app devices that are offline
- on app `hello`:
  - relay drains only the queue for that app's `group_id + device_id`
  - relay must not drain one shared group queue for all app devices

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
    "bundle_id": "com.neonnode.chat94app"
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
  "id": "stream-uuid",
  "body": {
    "delta": " world"
  },
  "ts": 1710000000000
}
```

`text_end` body:

```json
{
  "t": "text_end",
  "id": "stream-uuid",
  "body": {
    "text": "Hello world"
  },
  "ts": 1710000000000
}
```

Rules:

- the inner `id` for `text_delta` and `text_end` is the `stream_id`
- within a single `stream_id`, `text_delta.body.delta` is append-only
- receivers must concatenate deltas in arrival order for that `stream_id`
- `text_end` finalizes that same `stream_id`
- senders must not use later `text_delta` frames in the same `stream_id` to rewrite or replace earlier text

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
