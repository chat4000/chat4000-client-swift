# clawconnect-client-swift — agent notes

## Deploying the macOS app — ALWAYS copy the build into /Applications

The macOS app the user actually launches (Spotlight, Dock, the Cmd+Shift+2
hotkey — everything LaunchServices resolves) is `/Applications/chat4000.app`.
`xcodebuild` only writes to DerivedData; `open`-ing that DerivedData bundle by
path runs a DIFFERENT binary than the user's normal launch target, even though
both share bundle id `com.neonnode.chat94app` and the same version — so the user
never sees your changes through their normal launch.

Therefore: every time you build the macOS app (`chat4000mac` scheme), copy the
result into `/Applications/chat4000.app` and relaunch from there. This is a
standing, pre-authorized write to `/Applications` for THIS bundle only.

```
xcodebuild -project /Users/haimbender/dev/me/clawconnect/clawconnect-client-swift/chat4000/chat4000.xcodeproj \
  -scheme chat4000mac -destination 'platform=macOS' build
APP="$(xcodebuild -project /Users/haimbender/dev/me/clawconnect/clawconnect-client-swift/chat4000/chat4000.xcodeproj \
  -scheme chat4000mac -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2} /WRAPPER_NAME/{w=$2} END{print d"/"w}')"
pkill -x chat4000; sleep 1
rm -rf /Applications/chat4000.app
cp -R "$APP" /Applications/chat4000.app
open /Applications/chat4000.app
```

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

- `--domain-identifier`: `com.neonnode.chat94app` (App-Store target),
  `com.neonnode.chat94app.dev.hermes` (Hermes dev target), or
  `com.neonnode.chat94app.dev.openclaw` (OpenClaw dev target) — match the build
  you're debugging.
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
