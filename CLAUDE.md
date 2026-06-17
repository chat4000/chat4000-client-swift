# clawconnect-client-swift — agent notes

## Reading the iOS app's logs off the device

To read chat4000's own logs from the iPhone, **pull the app's log file** — do NOT
use `idevicesyslog` / `log show` / `log stream` / `log collect`. AppLog emits via
`NSLog("%@", line)`, which iOS redacts to `<private>` in the system **unified
log** (what those tools read when unattached). But AppLog also appends every line
to a plaintext file in the app sandbox — `Library/Logs/chat4000.log` — which is
full, unredacted text.

Pull it (works unattached, no code change; the installed builds are debug-signed
with `get-task-allow`):

```
xcrun devicectl device copy from \
  --device <DEVICE_UDID> \
  --domain-type appDataContainer \
  --domain-identifier com.neonnode.chat94app \
  --source Library/Logs/chat4000.log \
  --destination /tmp/chat4000_pulled.log
```

Then `grep`/`tail` the local file.

- `--domain-identifier`: `com.neonnode.chat94app` (App-Store target) or
  `com.neonnode.chat94app.dev` (dev target) — match the build you're debugging.
- Get `<DEVICE_UDID>` from `xcrun devicectl list devices` (the identifier column).
- `xcrun devicectl device process launch --console … <bundleid>` also shows
  readable text (it reads the app's stderr) but requires launching attached.

Dead ends for app logs (always redacted/empty): `idevicesyslog`, `log show`,
`log stream`, `log collect`. They read Apple's system-wide unified log, where the
app's text is `<private>`. The app's own file is the readable one.

## No memory files, ever

Never create, write, or edit any memory file — nothing under a `memory/`
directory and never `MEMORY.md`. The auto-memory system is OFF. Do not persist
anything there regardless of context, "remember this," or a goal/Stop hook. If
something is worth keeping, propose it in chat and let the user decide where it
goes.

## No creating images without explicit consent

Never create images without an explicit, per-instance "yes" from the user. This
covers Docker images (`docker commit`, `docker build`) — the 4.7GB `docker commit`
of `personal-hermes` is the exact thing that must not happen unprompted — and any
generated/AI image files. Reusing or running existing images is fine; minting new
ones is not, without a clear OK.
