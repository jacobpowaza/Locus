# Locus engineering report

## Repository audit and implementation

The baseline already had MapKit autocomplete, favorites and recents, walking and GPX playback, a route speed solver, a visual run editor, schedules, persisted checkpoints, and an idevice-based DVT connection. The implementation extended the existing map, route provider, run store, and executor. The sequence was destination and trip planning, connection and execution reliability, then verification.

- The map has persistent top search and an expandable bottom panel. Place cards lead to Drive To, Teleport To, walking, scheduling, and saved places. Home and Work have their own slots.
- The route planner offers MapKit alternatives when available and preserves the selected geometry for each leg. Stops can be edited and reordered. Saved trips replay from their stored origin. Route restart and Drive Again explicitly return to that origin.
- The same executor drives a manual trip and an automation. MapKit supplies route geometry and ETA. Valhalla matches that geometry to OpenStreetMap speed limits, and offsets apply only on matched roads with a posted limit. Unmapped sections use a labeled fallback. Custom speed zones override the target inside an outline drawn in the planner. [MapKit directions](https://developer.apple.com/documentation/mapkit/mkdirections), [Valhalla map matching](https://valhalla.github.io/valhalla/api/map-matching/api-reference/)
- Automated Runs keeps the original editor, recurrence, history, and storage. Drive blocks form an ordered list of stops. Runs can be copied into reusable templates. Step-level notifications are opt-in for scheduled runs. A scheduled occurrence is claimed before startup, and location-changing steps advance after the service reports success.

## Cellular and tunnel

The checked-in iOS target has one app, an idevice library, and an external LocalDevVPN launcher. It opens RemotePairing at the configured IPv4 peer, by default `10.7.0.1:49152`, negotiates the tunnel and RSD/RemoteXPC, then opens DVT LocationSimulation. The interface heuristic can detect a candidate `utun` without proving that the peer is reachable. The app code had no Wi‑Fi-only gate.

The upstream cellular report shows the LocalDevVPN peer refusing or timing out with cellular only despite the VPN reporting connected. The LocalDevVPN maintainer attributes this to iOS. This explains a failure mode at the start of RemotePairing, before a DVT session exists. The exact failure stage on the user’s device needs a signed build and device logs. An existing session may keep working after a path change if its transport remains reachable. A new cellular-only session is viable only if the configured peer remains reachable and the paired service completes all handshake stages. This checkout has no verified configuration that satisfies those conditions with LocalDevVPN. [LocalDevVPN cellular issue](https://github.com/jkcoxson/LocalDevVPN/issues/31), [LocalDevVPN packet tunnel source](https://github.com/jkcoxson/LocalDevVPN/blob/main/TunnelProv/PacketTunnelProvider.swift)

The Swift wrapper now queues native calls off the main thread, retains the borrowed RemoteXPC server until its DVT channel is released, and reports stage-specific native error codes. Playback holds confirmed progress through failed updates. Locus attempts the configured connection on any network and prompts for Wi‑Fi when a cold attempt fails on an observed cellular path. If clearing fails, Locus keeps the state marked uncertain and can retry clear after reconnecting. TLS and pairing verification stay in idevice. [idevice DVT binding](https://github.com/jkcoxson/idevice/blob/master/ffi/src/dvt/location_simulation.rs)

A built-in tunnel requires a packet-tunnel extension and signed Network Extension entitlement. This app bundles neither. Advanced Settings reports whether an extension is bundled. To verify the actual installed build’s signing, inspect the exact re-signed app and any extension with `codesign --display --entitlements :- /path/to/Locus.app` on a Mac. An on-device pairing record authorizes the developer protocol. It does not grant the packet-tunnel capability. No supported direct system location setter was identified for this iOS 18+ app target. [Network Extension configuration](https://developer.apple.com/documentation/xcode/configuring-network-extensions), [Apple entitlement diagnostics](https://developer.apple.com/documentation/bundleresources/diagnosing-issues-with-entitlements) A TCP connection to localhost alone is insufficient. Device logs show RemotePairing can accept the socket and reject the control channel when the connection originates on the same device. [Direct connection logs](https://github.com/Mak5er/AirCard-iOS/issues/13)

## Scheduling

Locus evaluates schedules while its process is running. Background location keeps active simulation eligible for background time, subject to iOS suspension. BackgroundTasks eligibility is opportunistic. A user can set a Shortcuts time trigger to open Locus. App Intents can expose foreground actions, and intent extensions have their own lifetime. Neither supplies a durable process for an exact-time, multi-hour DVT run. The app uses local notifications as a reminder and opens Automated Runs when tapped. It starts late inside the configured window or records the occurrence as missed and offers a manual start. History shows actual acknowledgments, interruptions, and errors. [BackgroundTasks eligibility](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate), [App Intents](https://developer.apple.com/documentation/appintents/getting-started-with-the-app-intents-framework), [Shortcuts time triggers](https://support.apple.com/guide/shortcuts/apd932ff833f/ios), [Local notifications](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)

## Cross-application validation

| Surface | Evidence on this checkout |
|---|---|
| Locus executor | Tested with a recording sink. Covers ordered locations, speed changes, stop acknowledgement, conflicts, and restart recovery. |
| iOS Core Location | Locus filters `isSimulatedBySoftware` fixes from its last actual-location marker and accepts no new actual fixes while simulating. A physical-device reading is pending. |
| Apple Maps and Google Maps | Device display, course, caching, and restored location are unverified. |
| Find My and Life360 | Device display and sharing behavior are unverified. Service-side checks, caching, and the selected sharing device can affect results. |
| Other Core Location apps | Compatibility is app-specific. The DVT call supplies latitude and longitude. Speed and heading in Locus are playback calculations. |

Apple exposes simulated-source metadata to Core Location clients. Observe Core Location on the test iPhone separately from any third-party display. Use accounts and sharing settings you control. [Apple Core Location source information](https://developer.apple.com/documentation/corelocation/cllocationsourceinformation/issimulatedbysoftware)

On the Simulator, search for an address and a business, open a place card, and teleport through the stub. Plan a drive with alternatives and two stops, compare all four modes, then start, pause, resume, finish, and replay. Save and reopen the trip and an automation. Test a one-time run in the foreground, then schedule a second run, close Locus, tap the reminder, and verify the late or missed outcome.

On a paired iPhone, repeat the trip and collect Advanced diagnostics for Wi‑Fi startup, cellular-only startup with Wi‑Fi disabled in Settings, Wi‑Fi-to-cellular handoff, helper disconnect and reconnect, device lock and unlock, and a force-quit and relaunch. Record the last confirmed position before each interruption and compare with the first accepted position after recovery. Clear the simulation and compare a fresh Core Location reading to the readings shown by each app. Record iOS version, device, carrier, helper version, signing method, observed network path, and FFI stage and code. See [device log collection](TESTING.md#3-physical-iphone-the-only-real-end-to-end-test).

## Build status

The starting commit passed 123 local core tests. Its existing macOS 26 CI job built the Simulator and unsigned IPA and passed the Simulator smoke test. The overhaul was verified with 133 passing Linux Swift package tests and an app source syntax parse. The current iOS build and Simulator checks are pending because this Linux host has no Xcode and the fork rejected workflow dispatch with Actions disabled. No physical iPhone was available. [Baseline CI run](https://github.com/jacobpowaza/Locus/actions/runs/41926370659)
