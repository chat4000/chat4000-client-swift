# clawconnect-client-swift — agent notes

## Deploying after a push — ALWAYS redeploy EVERY affected flavor (iOS dev + macOS)

This is a cross-platform (iPhone + macOS) project sharing one Sources tree.
Whenever you push a change, you ALSO deploy it — don't stop at the commit. Deploy
is part of "done", not a separate step the user has to ask for. "Deploy" means
EVERY user-runnable flavor the change touches, across BOTH platforms:

1. **Both iOS dev flavors** → install to the connected iPhone:
   `chat4000iphonedevhermes` and `chat4000iphonedevopenclaw`.
2. **The macOS app** → build the 3 mac flavors and copy each into its
   `/Applications` path, then relaunch (see the macOS section below).

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

## Deploying the macOS app — ALWAYS copy the builds into /Applications

macOS has THREE flavors (mirroring iPhone), each a distinct bundle id +
PRODUCT_NAME so all three coexist in `/Applications`:

  • `chat4000macdevhermes`   → `/Applications/chat4000-hermes.app`   (stage — the DAILY driver)
  • `chat4000macdevopenclaw` → `/Applications/chat4000-openclaw.app` (stage)
  • `chat4000macprod`        → `/Applications/chat4000.app`          (prod; bundle `com.neonnode.chat94app`)

The flavor is set by the per-target `APP_ENV` build setting (stage/prod), read at
runtime via Info.plist — NOT Debug/Release. The app the user launches (Spotlight,
Dock, hotkey — everything LaunchServices resolves) is the copy in `/Applications`;
`xcodebuild` only writes to DerivedData, and `open`-ing the DerivedData bundle runs
a DIFFERENT binary than the normal launch target. So every time you build a mac
flavor, copy it into its `/Applications` path and relaunch. Standing, pre-authorized
write to `/Applications` for these bundles.

The dev flavors (`…dev.hermes` / `…dev.openclaw`) need `-allowProvisioningUpdates`
— their macOS profiles are created on demand; that step fails with "No Accounts"
only when Xcode isn't open with the developer account signed in. `chat4000macprod`
already has a cached profile.

```
S=chat4000macdevhermes; APPNAME=chat4000-hermes   # or macdevopenclaw/chat4000-openclaw, or macprod/chat4000
xcodebuild -project /Users/haimbender/dev/me/clawconnect/clawconnect-client-swift/chat4000/chat4000.xcodeproj \
  -scheme "$S" -destination 'platform=macOS' -allowProvisioningUpdates \
  -derivedDataPath "/tmp/c4k-mac-$APPNAME" build
osascript -e 'tell application "chat4000" to quit' 2>/dev/null; pkill -x "$APPNAME"; sleep 1
rm -rf "/Applications/$APPNAME.app"
cp -R "/tmp/c4k-mac-$APPNAME/Build/Products/Debug/$APPNAME.app" "/Applications/$APPNAME.app"
open "/Applications/$APPNAME.app"
```

NOTE: `chat4000.app` is now PROD (it can't pair without a prod bot). The user's
daily Mac is `chat4000-hermes.app` (stage). Never overwrite `/Applications` with
a prod build before the stage flavor is built+ready, or you strand the daily app.

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
