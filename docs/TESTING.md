# Building & testing Locus

Locus is an iOS app (SwiftUI, iOS 18+). Building the app itself needs Xcode on
macOS, and Xcode only runs on macOS. This page covers what can be done where.

## What runs where

| Layer | Linux (this repo's dev box) | macOS CI (GitHub Actions) | Physical iPhone |
|---|---|---|---|
| Scheduled Runs engine: scheduling, DST/time zones, routes, speed profiles, ETA, executor, persistence, restart recovery | ✅ `scripts/test-core.sh` (Docker `swift:6.2`) | ✅ `swift test` | — |
| App compiles for iOS (SwiftUI, MapKit, UIKit) | ❌ no iOS SDK | ✅ `xcodebuild` for the Simulator and the device | — |
| App launches and runs a Scheduled Run | ❌ | ✅ Simulator smoke test (spoofing is **stubbed**) | ✅ |
| Real location spoofing (DVT → `locationd`) | ❌ | ❌ the Simulator has no developer tunnel | ✅ only here |
| Logs / crash reports / screenshots | — | ✅ uploaded as CI artifacts | ✅ `scripts/device-diagnostics.sh` (libimobiledevice, works on Linux) |

## 1. Core tests on Linux (no Mac needed)

```bash
scripts/test-core.sh
```

Uses a native `swift` if installed, otherwise the official `swift:6.2` Docker
image. The engine lives in `Locus/Scheduling/Core/` and imports only
Foundation; the root `Package.swift` builds those same files as the
`LocusSchedulingCore` module, and XcodeGen compiles them into the app. There
is one copy of the code.

Filter: `scripts/test-core.sh --filter SchedulerTests`

Trace for eyeballing motion realism:

```bash
mkdir -p outputs/trace
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e LOCUS_TRACE_DIR=/trace \
  -v "$PWD/outputs/trace":/trace -v "$PWD":/work -w /work swift:6.2 \
  swift test --scratch-path /work/.build --filter TraceExportTests
```

## 2. iOS build + Simulator smoke test (macOS CI)

`.github/workflows/ios.yml` runs on every push to a repo where Actions is
enabled:

1. `core-linux`: the engine tests on Ubuntu.
2. `ios` (macOS 26 runner, newest Xcode): `xcodegen generate` → `swift test`
   → `scripts/ios-sim-smoke.sh` → `scripts/build-unsigned-ipa.sh`.

The smoke test builds for the Simulator, installs, launches with the
DEBUG-only `-LocusDemoRun` argument (creates and starts a short run: set
location → wait 10 s → ~1 km drive), takes screenshots, kills and relaunches
the app mid-run (recovery path), and checks the app log
for the expected `[Locus][Run]` / `[Locus][SimStub]` lines and for crash
reports. The `locus://runs` deep link isn't covered, because iOS asks to
confirm `simctl openurl`. Artifacts: `outputs/sim/` (screenshots, `app.log`, `xcodebuild.log`,
`.xcresult`, crashes) and `outputs/Locus-unsigned.ipa`.

**Simulator caveat.** `Vendor/idevice/libidevice_ffi.a` contains only
`arm64` for iOS devices (no Simulator slice), and the Simulator has no
developer tunnel. Simulator builds therefore skip linking it
(`OTHER_LDFLAGS[sdk=iphoneos*]`) and use a stub `LocationEngine` that logs
`[Locus][SimStub] set lat,lon`. The Simulator proves that the UI and the
engine run on iOS. It does not prove that iOS accepted the spoofed
coordinates.

To use it: fork `ChrisMack32/Locus`, push, and open the **Actions** tab.
Locally on a Mac you can run the same scripts directly.

### Try it in a browser (Appetize.io, works from Linux)

Each CI run uploads a **`Locus-simulator`** artifact. It contains
`Locus-simulator.zip`, a universal (arm64 + x86_64) Debug Simulator build.

1. Download the artifact from the run's page on GitHub and unzip it once.
   You should end up with `Locus-simulator.zip`.
2. Sign in at [appetize.io](https://appetize.io), choose **Upload**, pick
   **iOS**, and upload `Locus-simulator.zip`.
3. Open the app in the browser. Simulator builds skip the pairing walkthrough
   (pass the launch argument `-LocusShowSetup` to see it), so you go straight
   to the map. Optionally add the launch argument `-LocusDemoRun` in
   Appetize's settings to start a demo run straight away.

Spoofing goes through the Simulator stub here too. You can use every screen
and run a schedule end to end, but nothing changes the device location.

## 3. Physical iPhone (the only real end-to-end test)

From Linux, without Xcode:

1. Get `Locus-unsigned.ipa` from the CI artifacts (or the Releases page).
2. Sideload it with SideStore / AltStore / Sideloadly / Feather. They re-sign
   it with your Apple ID.
3. Pair and connect LocalDevVPN as in [SETUP.md](../SETUP.md).
4. Plug the phone into the Linux box and run:
   ```bash
   sudo apt install libimobiledevice-utils usbmuxd   # once
   idevicepair pair                                    # once, tap Trust
   scripts/device-diagnostics.sh 300                   # 5 min of logs
   ```
   Output goes to `outputs/device-*/`: the filtered `locus.log`, the
   `[Locus]`-tagged lines, crash reports, and a screenshot if the Developer
   Disk Image is mounted.

The checklist is in [SCHEDULED_RUNS.md § Physical iPhone validation](SCHEDULED_RUNS.md#physical-iphone-validation).
