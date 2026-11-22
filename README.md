# Paqo

A light, simple run tracker for iPhone. Everything other run apps put behind a paywall is
free here: no accounts, no ads, and your runs stay on your phone.

Built for running in bursts. Paqo splits each run into **sprints and walks** automatically,
using the motion coprocessor (running vs walking), step cadence and GPS speed.

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

Later: voice updates, auto-pause, heart rate, treadmill mode, goal runs, pace alerts and
intervals.

## How the code is laid out

```
PaqoKit/                 Swift package
  Sources/PaqoCore/      Pure Swift (Foundation only): tracking engine, GPS filtering,
                         sprint/walk detection, splits, best efforts, records, storage.
                         Builds and tests on Windows, Linux and macOS.
  Sources/PaqoSensors/   iOS only: CoreLocation, CoreMotion (activity, pedometer,
                         barometer) and HealthKit wrappers that feed PaqoCore.
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

## Tuning

Sprint and walk thresholds live in `SegmentClassifier.Configuration`. By default, a sprint
is ≥ 2.5 m/s or ≥ 145 steps/min, and a walk is ≤ 1.9 m/s or ≤ 125 steps/min. GPS filtering
lives in `RunEngine.Configuration`. Both are plain values with tests around them.
