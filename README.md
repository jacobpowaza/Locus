# Locus

Free and open-source iPhone location teleport. Tap the map, search a place, or drive a route — Locus sends test coordinates to Apple’s **developer location service**. See the [validation matrix](docs/OVERHAUL.md) for cross-app and device-dependent behavior.

<p align="center">
  <img src="docs/screenshots/map.png" alt="Locus map with spoof pin" width="180" />
  <img src="docs/screenshots/spoofing.png" alt="Locus spoofing in 3D" width="180" />
  <img src="docs/screenshots/joystick.png" alt="Locus joystick controls" width="180" />
  <img src="docs/screenshots/route.png" alt="Locus route on map" width="180" />
</p>

## Features

- Map search for businesses, addresses, cities, landmarks, coordinates, and supported map links
- Place cards for teleport, drive, walk, schedule, and save. Home, Work, recents, favorites, and named collections
- Route alternatives, waypoints, saved road trips, and a live navigation dashboard
- Follow Speed Limit, Above Speed Limit, Variable Speed, and Constant Speed. MapKit reference speeds and traffic stops are labeled as estimates or simulations
- **Automated Runs** with a visual step editor, saved templates, schedules, history, and reminders. See [how scheduling works](docs/SCHEDULED_RUNS.md)
- Live joystick, GPX import, first-run setup, and connection diagnostics

## Install

See [SETUP.md](SETUP.md) for full steps. Grab a prebuilt IPA from [Releases](https://github.com/ChrisMack32/Locus/releases), or build from source below.

Bundle ID: `com.chrismack.locus`

### LiveContainer

File pickers often don’t work inside LiveContainer. Use one of these:

1. Long-press **Locus** → **Settings** → enable **Fix File Picker**, then try Import again.
2. Share the pairing file **into LiveContainer → Locus**.
3. Copy the RPPairing plist contents → in Locus use **Paste RPPairing from clipboard** (setup or Settings).

## How it works

Locus uses the MIT-licensed [idevice](https://github.com/jkcoxson/idevice) FFI to talk to Apple’s DVT location simulation over an on-device developer tunnel (the same class of mechanism Xcode uses).

**iOS 27:** Settings → **Pair on this iPhone** advertises `_remotepairing-pairable-host._tcp`. Confirm the 6-digit code under Settings › Privacy & Security › Developer Mode › Pair with Host — no computer.

**iOS 18–26:** import an **RPPairing** file once from [idevice_pair](https://github.com/jkcoxson/idevice_pair/releases).

Also install **[LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044)** (loopback tunnel, default `10.7.0.1`), then sideload Locus.

Locus tries the configured connection on any network. LocalDevVPN documents a cellular-only peer reachability problem on affected iPhones. Join Wi‑Fi if a new connection fails. See [the connection audit](docs/OVERHAUL.md#cellular-and-tunnel).

### Location in other apps

iOS can flag developer-generated fixes as simulated. Apps may use their own
location validation or server-side logic. See the [compatibility matrix](docs/OVERHAUL.md#cross-application-validation)
for what was tested.

## Build

Building from source needs an Apple Developer account (free or paid) for code signing. The published IPA does **not** — just sideload it.

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) if needed: `brew install xcodegen`
2. Set your **Team ID** in `project.yml` (`DEVELOPMENT_TEAM`), *or* pick your team under Xcode → Signing & Capabilities after generating the project.
3. Generate and open:

```bash
xcodegen generate
open Locus.xcodeproj
```

Or build from the CLI (replace with your Team ID from [developer.apple.com/account](https://developer.apple.com/account) → Membership):

```bash
xcodegen generate
xcodebuild -project Locus.xcodeproj -scheme Locus -configuration Release \
  -destination 'generic/platform=iOS' DEVELOPMENT_TEAM=YOUR_TEAM_ID build
```

## Tests

The Scheduled Runs engine is plain Swift and is tested on Linux or macOS with `scripts/test-core.sh`. The app build, the Simulator smoke test and the unsigned IPA run on macOS CI (`.github/workflows/ios.yml`). See [docs/TESTING.md](docs/TESTING.md).

## License

MIT. `Vendor/idevice` contains the idevice FFI (MIT). Locus is an independent open-source project and is not affiliated with Mirage / Wapixel.
