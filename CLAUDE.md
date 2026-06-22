# clawconnect-client-swift — agent notes

## Deploying after a push — ALWAYS redeploy EVERY affected flavor (iOS dev + macOS)

This is a cross-platform (iPhone + macOS) project sharing one Sources tree.
Whenever you push a change, you ALSO deploy it — don't stop at the commit. Deploy
is part of "done", not a separate step the user has to ask for. "Deploy" means
EVERY user-runnable flavor the change touches, across BOTH platforms:

1. **Both iOS dev flavors** → install to the connected iPhone:
   `chat4000iphonedevhermes` and `chat4000iphonedevopenclaw`.
2. **The macOS app** → build `chat4000mac` and copy it into
   `/Applications/chat4000.app`, then relaunch (see the macOS section below).

Because the Sources tree is shared, almost any change compiles into the macOS app
too — so redeploying macOS is the DEFAULT, not an afterthought. The only time you
skip a platform is when the change is provably platform-specific (e.g. inside an
`#if os(iOS)` / NSE-only path that macOS never compiles). When unsure, deploy
both. Do NOT report "deployed" after doing only iOS — that's the miss this rule
exists to prevent.

Do NOT auto-deploy `chat4000iphoneappstore`: its bundle id is the production
`com.neonnode.chat94app`, so installing a debug build CLOBBERS the user's real
App Store / TestFlight install. Ask first. NSE targets ship embedded in their host
app (not installed separately); `chat4000Tests` is run, not installed.

Standing, pre-authorized: building + installing the iOS DEV apps to the user's own
connected device, and copying the macOS build into `/Applications/chat4000.app`,
need no extra yes.

How (build for the device, then `devicectl install` each `.app`):

```
UDID="$(xcrun devicectl list devices 2>/dev/null | awk '/connected/{print $3; exit}')"
cd /Users/haimbender/dev/me/clawconnect/clawconnect-client-swift/chat4000
for S in chat4000iphonedevhermes chat4000iphonedevopenclaw; do
  xcodebuild -project chat4000.xcodeproj -scheme "$S" \
    -destination "id=$UDID" -derivedDataPath build/dd-deploy build
done
D=build/dd-deploy/Build/Products/Debug-iphoneos
for APP in chat4000iphonedevhermes.app chat4000iphonedevopenclaw.app; do
  xcrun devicectl device install app --device "$UDID" "$D/$APP"
done
```

Notes:
- Get the live UDID from `xcrun devicectl list devices` (pick the `connected`
  row) — don't hardcode it; the user has more than one device registered.
- A locked phone can block install/launch — if install fails for that reason,
  say so (per the XcodeBuildMCP notes: build → install, don't fight the lock).
- This is the iOS analogue of the macOS "/Applications" rule below: a build the
  user can't launch on their real device is not deployed.

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
