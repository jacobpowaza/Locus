# Automated Runs

Automated Runs automate location changes. You build a run from blocks, then
start it yourself or let it start on a schedule. Open it from **Automated Runs**
in the map’s bottom panel, or with `locus://runs`.

Drives started from the map (search a place → **Drive**) use the same engine
as a one-off run that isn't saved to the list.

## Steps

| Step | What it does |
|---|---|
| **Teleport** (Set Location) | Jumps to a place instantly (map pin, search, favorite, recent, current spoof). |
| **Drive To** | Drives along Apple Maps roads from the current simulated location. Can override the speed for that one leg ("Custom Speed"). |
| **Wait** | Stays put for a set duration. |
| **Wait Until** (Start At) | Holds until a time of day (same day, or 1–6 days later) in the run's time zone. |
| **Change Speed** (Set Speed) | Changes the speed used by the drives that follow. |
| **Turn Off Locus** (Stop Spoofing) | Ends simulation, so the phone goes back to real GPS. |
| **Repeat** | Repeats the previous *N* steps *K* more times. Repeating the whole run on a schedule is done with the run's **Schedule** instead. |

You can add, edit (tap), duplicate (swipe or long-press), delete, and reorder
blocks (Reorder, long-press → Move Up/Down, or drag). Every block shows its
projected start time. Validation errors and warnings appear on the block they
apply to.

Example (Commute template): Start At 10:00 → Set Location Home → Wait 15 min
→ Start At 10:30 → Set Speed: Follow limit → Drive To Work. The run arrives
around 10:50 and stays at Work.

## Traffic realism

Under **Driving** in a run (and in the map's Drive sheet) you can turn on:

- **Stop at red lights** — some intersections hold the car for a random time,
  from about a fifth of the limit up to the limit you pick (30 s – 3 min).
- **Stop at stop signs** — brief 2–4 s full stops at many turns and on slow
  residential streets.
- **Vary speed naturally** — the target drifts about ±8 % every few hundred metres.

MapKit doesn't expose where real signals and signs are, so stops are placed at
the route's turns (heading change > 50°) and at plausible intersection spacing
on roads slower than ~45 mph. Stops are seeded from the step's ID, so the
editor's estimate matches the actual run. The car brakes into each stop and
pulls away with the normal acceleration limits; the live view shows "Waiting
at a red light". Settings are stored in `MotionSettings.realism` (optional, so
older saved runs decode unchanged).

## Speed

| Mode | Behaviour |
|---|---|
| Follow speed limit | target = road reference speed |
| Constant | target = fixed value (e.g. 35 mph) |
| Above Speed Limit | Reference plus a fixed or percentage offset |
| Variable Speed | Reference with seeded variation and configured motion and traffic assumptions |
| Below limit | reference − offset |
| Custom (per Drive To) | any of the above for one leg |

Every drive also gets the following treatment:

- **Smoothing** (can be turned off): acceleration up to 2.0 m/s², braking up
  to 2.5 m/s². Speed changes happen at limit boundaries: the car brakes
  before a slower zone and only speeds up after entering a faster one.
- **Turns** (can be turned off): corner speed is capped by lateral
  acceleration, √(3 m/s² × radius), with a floor of about 7 mph.
- **Arrival**: the car always stops at the destination.

**About "speed limit" data.** Apple MapKit does not expose posted speed limits.
When a route has none, which is always the case with MapKit, Locus uses Apple's
ETA-derived **route average speed**, and the UI labels it *"Estimated — route
average"* or *"Limit (est.)"*. If there's no ETA either, it falls back to a
default driving speed (13.4 m/s ≈ 30 mph), labelled the same way. Locus never
presents a fallback as a posted limit. The engine already supports real
per-road limits (`SpeedLimitSpan`) if a provider that has them is added later.

The ETA is recomputed whenever the speed settings change, both in the editor
preview and live. During a run, the **Speed** button re-solves the current
leg from the car's current speed, plus later legs until the next Set Speed.
Legs with a custom speed keep it.

## Live run & history

The live dashboard shows: a map with the route and a distinct **Simulated**
vehicle marker, simulated speed, the limit or estimate, remaining distance for
the leg and the whole run, elapsed time, ETAs, step progress, and Pause /
Resume / Skip / Speed / End (stay put, or stop spoofing). A banner on the main
map follows the active run.

History records completed, failed, cancelled, and missed runs, each with its
log. **Export diagnostics** shares a text report that includes platform notes.

Manual control pauses the active run instead of fighting it. That covers
Teleport, the joystick, Follow route, and Stop.

## Scheduling engine

- Runs, history, the active-run checkpoint, and the offline route cache are
  stored as JSON under `Application Support/ScheduledRuns/`. Writes are
  atomic. Unreadable files are set aside, not overwritten.
- Schedules are manual, once, or weekly by weekday. A schedule uses a fixed
  time zone or follows the device's.
- DST: a time that doesn't exist (02:30 on spring-forward day) runs at the
  next valid time (03:00). A repeated time (01:30 on fall-back day) runs once.
  Unit tests cover both.
- Clock changes: Waits and drives advance on a monotonic clock, so changing
  the device clock doesn't make the car jump. Start At follows the wall clock.
  Locus reacts to `significantTimeChange` and time-zone changes.
- Missed and late runs: each occurrence is handled at most once. If Locus
  wasn't running at the start time, the run starts late within the run's
  late-start window (Skip / 5 min / 15 min / 1 h). Otherwise it is recorded as
  **Missed**. After a multi-day gap, each missed day gets its own record.
- Conflicts: only one run can control the location at a time. The editor
  warns when two schedules overlap, using the estimated durations. At run
  time, the later run is skipped, logged, and a notification is posted.
- Conflicting steps: a drive that overruns the next Start At is flagged in the
  preview with how late it will be. At run time the next step starts as soon
  as the drive finishes, and the lateness is logged.
- Route failures: live MapKit routing is tried first, then the last good route
  for the same leg (cached on disk), and the log notes when the cached route
  was used. With neither, the run fails with an actionable message. Malformed
  routes are rejected: empty, all-NaN, single-point, or ending more than 2 km
  from the destination.
- Restart recovery: the run is checkpointed every 15 seconds and at step
  changes. A relaunch restores the last checkpoint **paused** until you
  choose to resume.
- Tunnel drops: playback holds at the last confirmed position while Locus
  retries. Repeated failures pause the run. Teleport, arrival, and clearing
  the simulation are recorded after the device service responds successfully.
- Occurrence claims are persisted before starting. If Locus closes during
  preparation, recovery records the unresolved occurrence as missed and
  leaves manual start available.

## Platform restrictions (read this)

Locus spoofs by pushing coordinates through Apple's developer
location-simulation service over the LocalDevVPN tunnel. That code runs
**inside the Locus process**. iOS has no API that wakes a suspended or killed
app at an exact time.

| Situation | Behaviour |
|---|---|
| Locus in the foreground | The scheduler evaluates due runs and advances a drive about once a second. Connection and route availability still affect execution. |
| Locus in the background, process alive | Background location during an active simulation is best effort. iOS may suspend or end Locus. |
| Locus suspended or closed | A local reminder can appear about a minute after the scheduled time if notifications are authorized. Tap it to open Automated Runs. Within the late-start window, Locus can start the occurrence. After the window, it records a miss and offers Start Now. |
| Relaunch during a run | The last checkpoint opens paused. |

Other limits:

- iOS receives only coordinates. The DVT service has no speed or course
  input, so other apps compute speed from successive fixes. The speed Locus
  shows is labelled *Simulated*.
- Simulation requires pairing and a reachable developer service. See the
  [cellular and tunnel audit](OVERHAUL.md#cellular-and-tunnel).
- BackgroundTasks supplies an earliest eligibility time. User-configured
  Shortcuts can open Locus, and a foreground App Intent could expose the same
  entry point. Locus uses in-process scheduling and reminders. See the
  [scheduling design](OVERHAUL.md#scheduling).

Battery: the timer runs at 1 s only while a drive is moving. During Waits
and Start At it ticks at most every 15 s, and every 60 s when idle. Location
updates are pushed only when the position changes; holds rely on
SpoofSession's existing 8 s re-send.

## Code map

| Path | Role |
|---|---|
| `Locus/Scheduling/Core/` | Platform-free engine (Foundation only): `GeoMath`, `Speed`, `DriveProfile`, `RunModel`, `RunValidator`, `RunPlan`, `RunCompiler`, `RunExecutor`, `RunScheduler`, `RunStore`, `RunCoordinator` |
| `Locus/Scheduling/ScheduledRunsBridge.swift` | MapKit route provider, the SpoofSession location sink, notifications |
| `Locus/Scheduling/ScheduledRunsController.swift` | SwiftUI `ObservableObject`, timer, lifecycle |
| `Locus/Features/ScheduledRuns/` | Dashboard, editor, blocks, location picker, speed panel, timeline, live dashboard, history |
| `Tests/LocusSchedulingCoreTests/` | Unit and integration tests |

## Physical iPhone validation

Use the [device and compatibility checklist](OVERHAUL.md#cross-application-validation).
