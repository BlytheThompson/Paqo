# Paqo

A light, simple run tracker for iPhone. Everything other run apps put behind a paywall is
free here: no accounts, no ads, and your runs stay on your phone.

Built for running in bursts. Paqo splits each run into **sprints and walks** automatically,
using the accelerometer (step rhythm and impact), the motion coprocessor (running vs
walking), the pedometer and GPS speed.

## What v1 does

- **Start:** one tap, 3-2-1 countdown, go. Pause and resume by hand.
- **Live screen:** the map comes first, with your route drawn in as you go (sprints in mint,
  walks in grey). Below it are time, distance, current pace and average pace, plus a
  "Sprint 4 · 0:42" chip.
- **Lock screen and Dynamic Island:** time, distance, pace, sprint/walk state and a
  pause/resume button.
- **Summary:** coloured route, splits per mile or km, pace chart, barometric elevation chart,
  and every sprint with its distance, time and top speed.
- **History:** every run, with weekly, monthly and yearly totals.
- **Records:** fastest 1K, mile, 5K, 10K and half marathon (from any stretch of any run),
  longest run, sprint records and weekly streaks.
- **Apple Health:** runs are saved as running workouts with their route. You can turn this
  off in Settings.
- **Settings:** a miles/km switch.

## What v1.1 adds

- **Sharper sprint detection:** the accelerometer (50 Hz) gives step cadence and impact
  intensity every half second. When you finish, Paqo re-labels the whole run second by
  second, looking both ways in time, so sprint start and end times land within about a
  second.
- **Smoother route:** a Kalman filter blends GPS position, GPS speed and your steps, and
  holds still when your feet do. On finish the route is smoothed again with the whole run
  in view. GPS wobble no longer adds distance.
- **Sprint stats and trends:** for every sprint: average and peak speed, pace, time to peak,
  cadence, climb, the rest after it and how much it faded. For every run: time sprinting,
  sprint-to-rest ratio and fade across sprints. A **Trends** tab charts all of it by week or
  month. Records gains "fastest sprint".
- **Heatmap and replay:** History has a map of every route (or just your sprints). Any run
  can be replayed on its map at 10×, 30× or 60×.
- **Backups in open formats:** pick a folder (iCloud Drive, OneDrive…) and every run is
  written there as it's saved: `runs.csv`, `sprints.csv`, plus a JSON and GPX file per run.
  You can also export everything as one zip, and import runs back.
- **Sensor recorder:** each run's raw sensor data is kept (last 20 runs) so detection can be
  tuned to your real runs. Runs can be **re-processed** with newer settings.

Later: voice updates, auto-pause, heart rate, treadmill mode, goal runs, pace alerts and
intervals.

## How the code is laid out

```
PaqoKit/                 Swift package
  Sources/PaqoCore/      Pure Swift (Foundation only): tracking engine, Kalman route
                         filter, step rhythm, sprint/walk detection, sprint stats, trends,
                         records, heatmap, replay, sensor logs, CSV/JSON/GPX export,
                         backups. Builds and tests on Windows, Linux and macOS.
  Sources/paqo-replay/   Command-line tool: replays a sensor log on any computer.
  Sources/PaqoSensors/   iOS only: CoreLocation, CoreMotion (activity, pedometer,
                         barometer, accelerometer) and HealthKit wrappers.
  Tests/PaqoCoreTests/   Unit tests, including simulated sprint/walk runs.
App/                     SwiftUI app (screens, run controller, Live Activity control)
Widget/                  Live Activity (lock screen + Dynamic Island)
Shared/                  Code compiled into both the app and the widget
project.yml              XcodeGen spec; the Xcode project is generated from it on CI
.github/workflows/       Manual "Build IPA" workflow
docs/                    Design notes
```

## Developing without a Mac

### 1. Test the core logic locally (free, works on Windows)

You need the [Swift toolchain for Windows](https://www.swift.org/install/windows/).

```bash
cd PaqoKit
swift test
```

All tracking maths lives in `PaqoCore`, so most changes can be checked here before any
cloud build.

### 2. Build the IPA on GitHub (manual)

The workflow only runs when you start it, so pushing code costs nothing. To start it,
either go to **Actions → Build IPA → Run workflow** on GitHub, or run:

```bash
gh workflow run build-ipa.yml
```

The build takes about 5–10 minutes on a `macos-26` runner (Xcode 26.6). It runs the core
tests, generates the Xcode project with XcodeGen, builds an unsigned archive and packages
`Paqo.ipa`.

To download the latest IPA:

```bash
gh run download --name "Paqo-<run number>"
```

### 3. Sideload

Install `Paqo.ipa` with a sideloading tool and your Apple ID. A free Apple ID has a few
limits:

- The app has to be reinstalled every 7 days.
- Paqo uses 2 app IDs (the app plus its Live Activity widget). A free account can register
  10 app IDs per week.
- If the tool says the bundle ID `com.paqo.app` is taken, let it change the bundle ID.
- If Apple Health saving fails after sideloading, the re-signed build didn't keep the
  HealthKit capability. Tracking still works, and the run summary shows the error.

On first launch, iOS asks for these permissions:

- **Location:** "While Using the App" is enough. Paqo keeps tracking in your pocket.
- **Motion & Fitness:** sprint detection, cadence and the barometer.
- **Apple Health:** only if saving to Health is on.

## Sensor logs and tuning

With **Settings › Sensor logs** on (the default), Paqo saves each run's raw sensor data:
`meta.json` plus `gps.csv`, `activity.csv`, `pedometer.csv`, `altimeter.csv`, `accel.csv` and
`events.csv`, about 6–9 MB per hour. Logs for the last 20 runs are kept. To tune detection:

1. In a run's ⋯ menu, tap **Share sensor log** and save the zip somewhere the PC can reach
   (OneDrive, iCloud Drive for Windows, email).
2. Put it in `private/` in this repo. **Never commit real logs or backups**: they contain
   your routes, including where you live. `private/` is gitignored.
3. Replay it through the engine, optionally with different settings:

```bash
cd PaqoKit
swift run paqo-replay ../private/paqo-sensor-log-1a2b3c4d.zip
swift run paqo-replay ../private/paqo-sensor-log-1a2b3c4d.zip --set sprintCadence=150 --set switchPenalty=4
```

After a build with new settings, **Re-process** (per run, or all at once in Settings)
re-runs saved logs so older runs pick up the improvements. Apple Health keeps the original
numbers.

## Backups

**Settings › Backup › Auto-backup folder**: every run you save, rename or delete is written
to `Paqo Backup/` in that folder. Paqo only ever touches the run that changed, and never
erases anything (deleted runs move to `deleted/`), so reinstalling Paqo can't wipe a backup.
**Export all runs** makes one zip; **Import runs** reads a backup folder, zip or JSON files
back in. See `README.txt` inside any backup for every column.

## Tuning

Sprint and walk thresholds live in `SegmentClassifier.Configuration` (speed, cadence and
accelerometer intensity), whole-run re-segmentation in `Resegmenter.Configuration`, and the
route filter in `RouteFilter.Configuration`; all of them hang off `RunEngine.Configuration`.
`swift run paqo-replay --help` lists every setting. When results change, bump
`RunEngine.version` so the app offers to re-process older runs.
