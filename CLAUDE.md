# clawconnect-client-swift — agent notes

## Deploying after a push — ALWAYS redeploy EVERY affected flavor (iOS dev + macOS)

This is a cross-platform (iPhone + macOS) project sharing one Sources tree.
Whenever you push a change, you ALSO deploy it — don't stop at the commit. Deploy
is part of "done", not a separate step the user has to ask for. "Deploy" means
EVERY user-runnable flavor the change touches, across BOTH platforms:

1. **The THREE deployable iOS flavors** → install to the connected iPhone:
   `chat4000iphonedevhermes`, `chat4000iphonedevopenclaw`, and
   `chat4000iphonelocalprod` (prod backend, dev-signed, bundle
   `com.neonnode.chat94app.localprod`, display "chat4000 localprod").
2. **The THREE deployable macOS flavors** → build each and copy into its
   `/Applications` path, then relaunch (see the macOS section below):
   `chat4000macdevhermes`, `chat4000macdevopenclaw`, `chat4000maclocalprod`.

Because the Sources tree is shared, almost any change compiles into the macOS app
too — so redeploying macOS is the DEFAULT, not an afterthought. The only time you
skip a platform is when the change is provably platform-specific (e.g. inside an
`#if os(iOS)` / NSE-only path that macOS never compiles). When unsure, deploy
both. Do NOT report "deployed" after doing only iOS — that's the miss this rule
exists to prevent.

NEVER auto-deploy the two REAL distributions — they are how end users install,
and a local build would clobber them:
- **iOS `chat4000iphoneappstore`** (bundle `com.neonnode.chat94app`) — installs
  from the **App Store**. We don't touch it. (A debug build over it clobbers the
  user's real App Store / TestFlight install.)
- **macOS `chat4000macprod`** (bundle `com.neonnode.chat94app`, `chat4000.app`) —
  ships as the **notarized DMG downloaded from chat4000.com**. We don't auto-copy
  it into `/Applications`; it's built only for the DMG release pipeline
  (`scripts/build-dmg.sh` → S3 `s3://chat4000.com/downloads/`).

That's exactly why the `localprod` flavors exist: a dev-signed, own-bundle-id
build on the PROD backend so you can test prod end-to-end WITHOUT clobbering the
store/DMG install. Deploy `localprod`, never the real-distribution prod.

NSE targets ship embedded in their host app (not installed separately);
`chat4000Tests` is run, not installed.

Standing, pre-authorized: building + installing the iOS DEV apps to the user's own
connected device, and copying the macOS build into `/Applications/chat4000.app`,
need no extra yes.

How (build for the device, then `devicectl install` each `.app`):

```
UDID="$(xcrun devicectl list devices 2>/dev/null | awk '/connected/{print $3; exit}')"
cd /Users/haimbender/dev/me/clawconnect/clawconnect-client-swift/chat4000
for S in chat4000iphonedevhermes chat4000iphonedevopenclaw chat4000iphonelocalprod; do
  xcodebuild -project chat4000.xcodeproj -scheme "$S" \
    -destination "id=$UDID" -allowProvisioningUpdates -derivedDataPath build/dd-deploy build
done
D=build/dd-deploy/Build/Products/Debug-iphoneos
for APP in chat4000iphonedevhermes.app chat4000iphonedevopenclaw.app chat4000iphonelocalprod.app; do
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

## Deploying the macOS app — ALWAYS copy the builds into /Applications

macOS has FOUR flavors, each a distinct bundle id + PRODUCT_NAME so they coexist
in `/Applications`. THREE are deployable (auto-copied on every push); the fourth
(`chat4000macprod`) is the real DMG distribution and is NEVER auto-deployed:

  • `chat4000macdevhermes`   → `/Applications/chat4000-hermes.app`     (stage — the DAILY driver) — DEPLOY
  • `chat4000macdevopenclaw` → `/Applications/chat4000-openclaw.app`   (stage) — DEPLOY
  • `chat4000maclocalprod`   → `/Applications/chat4000-localprod.app`  (PROD backend, dev-signed, bundle `…localprod`) — DEPLOY
  • `chat4000macprod`        → `/Applications/chat4000.app`            (REAL prod; bundle `com.neonnode.chat94app`) — DMG-ONLY, do NOT auto-deploy

`chat4000macprod` is built only for the notarized DMG release
(`scripts/build-dmg.sh` → `s3://chat4000.com/downloads/` → linked from
chat4000.com). The user gets `chat4000.app` by downloading that DMG; a local copy
must never overwrite it. Test prod with `chat4000maclocalprod` instead.

The flavor is set by the per-target `APP_ENV` build setting (stage/prod), read at
runtime via Info.plist — NOT Debug/Release. The app the user launches (Spotlight,
Dock, hotkey — everything LaunchServices resolves) is the copy in `/Applications`;
`xcodebuild` only writes to DerivedData, and `open`-ing the DerivedData bundle runs
a DIFFERENT binary than the normal launch target. So every time you build a mac
flavor, copy it into its `/Applications` path and relaunch. Standing, pre-authorized
write to `/Applications` for these bundles.

The dev + localprod flavors (`…dev.hermes` / `…dev.openclaw` / `…localprod`) need
`-allowProvisioningUpdates` — their macOS profiles are created on demand; that
step fails with "No Accounts" only when Xcode isn't open with the developer
account signed in. `chat4000macprod` already has a cached profile.

```
# Deployable flavors only (NOT chat4000macprod — that's DMG-only):
S=chat4000macdevhermes; APPNAME=chat4000-hermes   # or macdevopenclaw/chat4000-openclaw, or maclocalprod/chat4000-localprod
xcodebuild -project /Users/haimbender/dev/me/clawconnect/clawconnect-client-swift/chat4000/chat4000.xcodeproj \
  -scheme "$S" -destination 'platform=macOS' -allowProvisioningUpdates \
  -derivedDataPath "/tmp/c4k-mac-$APPNAME" build
osascript -e "tell application \"$APPNAME\" to quit" 2>/dev/null; pkill -x "$APPNAME"; sleep 1
rm -rf "/Applications/$APPNAME.app"
cp -R "/tmp/c4k-mac-$APPNAME/Build/Products/Debug/$APPNAME.app" "/Applications/$APPNAME.app"
open "/Applications/$APPNAME.app"
```

NOTE: the user's daily Mac is `chat4000-hermes.app` (stage). `chat4000.app` is the
REAL prod and is owned by the downloaded DMG — never overwrite it with a local
build; deploy `chat4000-localprod.app` to exercise the prod backend locally.

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
  `com.neonnode.chat94app.dev.hermes` (Hermes dev target),
  `com.neonnode.chat94app.dev.openclaw` (OpenClaw dev target), or
  `com.neonnode.chat94app.localprod` (local-prod target) — match the build
  you're debugging.
- Get `<DEVICE_UDID>` from `xcrun devicectl list devices` (the identifier column).
- `xcrun devicectl device process launch --console … <bundleid>` also shows
  readable text (it reads the app's stderr) but requires launching attached.

Dead ends for app logs (always redacted/empty): `idevicesyslog`, `log show`,
`log stream`, `log collect`. They read Apple's system-wide unified log, where the
app's text is `<private>`. The app's own file is the readable one.

## Millisecond timestamps in logs

Logs must use ms-precision ISO-8601 (`…:56.480Z`, not whole-second `…:56Z`) — so
client lines can be ordered against server (ws-gateway/registrar) logs. `AppLog`
already does this; keep it for any new logger/timestamped output.

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
