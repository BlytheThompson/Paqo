# Paqo v1 — Design

Date: 2026-11-21 · Status: approved ("That all looks right, go ahead and build it")

## Intent

Paqo is a light, intuitive run tracker for iPhone (owner's device: iPhone 17 Pro Max). Many
features in other run apps sit behind paywalls even though they are straightforward to build;
Paqo gives them away and leans on the phone's sensors for precision.

The owner runs in free-form bursts: sprint as long as possible, walk to recover, repeat until
done. v1 is about tracking that kind of run really well.

## Goals (v1)

- **Start:** one big Start button → 3-2-1 countdown → recording. Manual pause/resume only.
- **Sprint/walk auto-detection:** the run is split into sprint and walk segments automatically
  using motion activity (running vs walking), pedometer cadence and GPS speed.
- **Live screen, map first:** route draws in (sprints in accent, walks grey); below it time,
  distance, current pace, average pace, and a chip such as "Sprint 4 · 0:42" or "Walk".
- **Lock screen + Dynamic Island (Live Activity):** time, distance, pace, sprint/walk state,
  pause/resume button. Ending a run is only possible in the app.
- **Run summary:** route map coloured by segment, headline stats, splits per mile/km, pace chart,
  barometric elevation chart, sprint list (distance, time, top speed each).
- **History:** list of runs plus weekly / monthly / yearly totals.
- **Records:** fastest 1K / mile / 5K / 10K / half (best stretch of any run), longest run
  (distance and time), sprint records (top speed, longest sprint by distance and time, most
  sprints in a run), streaks (weeks in a row, biggest week, biggest month).
- **Apple Health:** each run saved automatically as a running workout with route; Settings toggle.
- **Settings:** miles/kilometres switch, Health toggle.
- **Pace and speed:** pace for overall run and splits; speed (mph / km/h) for sprint top speeds.
- **Look:** clean and minimal, dark only: charcoal background, single electric-mint accent,
  big clean numbers.

## Non-goals (later versions)

Voice updates, auto-pause, heart rate, indoor/treadmill mode, goal runs, pace alerts, intervals,
Apple Watch app, cloud sync, social features.

## Anti-goals

- Paywalls, accounts, ads.
- Losing a run: a crash or kill mid-run must not lose what was recorded.
- Accidentally ending a run from the lock screen.

## Constraints

- No Mac. Development happens on Windows with Swift 6.3.3 installed; anything that does not
  touch Apple frameworks must compile and be unit-tested locally.
- iOS builds run on GitHub Actions `macos-26` runners (Xcode 26.6), triggered **manually only**
  (`workflow_dispatch`) so pushes never spend build minutes.
- Distribution is a sideloaded IPA (owner uses a free Apple ID re-signing tool). Capabilities
  must work under that: no iCloud, no push. HealthKit may or may not survive re-signing, so
  every HealthKit call must fail gracefully.

## Approaches considered

1. **Swift package core + XcodeGen app (chosen).** All tracking maths (filtering, distance,
   sprint/walk detection, splits, best efforts, records, streaks, storage) lives in a
   Foundation-only Swift package that builds and tests on Windows. A thin iOS layer wraps
   CoreLocation / CoreMotion / HealthKit / ActivityKit. The Xcode project is generated on CI
   from `project.yml`, so no hand-edited `.pbxproj`.
2. **Everything inside one Xcode app target.** Simpler layout, but nothing could be compiled or
   tested before a cloud build; every mistake costs a CI round trip.
3. **Cross-platform framework (Flutter / React Native).** Testable on Windows, but Live
   Activities, the motion coprocessor, barometer and HealthKit all need native code anyway, and
   it works against "light".

Chosen because it moves the most logic into code we can verify for free.

## Technical design (builder's calls)

- **iOS 17+**, SwiftUI, Observation, MapKit for SwiftUI, Swift Charts, ActivityKit with an
  interactive Live Activity (`LiveActivityIntent` for pause/resume).
- **Package `PaqoKit`:** `PaqoCore` (Foundation only) and `PaqoSensors` (iOS-only, compiled out
  elsewhere via `#if os(iOS)`).
- **Sensors:** CoreLocation `.fitness` best accuracy with background updates and
  `CLBackgroundActivitySession`; `CMMotionActivityManager`; `CMPedometer` (steps, cadence);
  `CMAltimeter` relative altitude (barometer) for elevation, anchored to GPS altitude.
- **Distance:** WGS-84 local ellipsoid approximation between accepted fixes. Fixes rejected for
  poor accuracy (> 25 m), out-of-order timestamps, impossible speed (> 12.5 m/s); a stationary
  gate (no steps / stationary activity + near-zero speed) stops GPS jitter adding distance;
  movement during a manual pause is never counted.
- **Sprint/walk detection:** per-fix evidence score from activity, cadence and speed;
  hysteresis (walk→sprint after 3 s, sprint→walk after 4 s) with the boundary back-dated to
  when the evidence changed; post-run pass merges blips (sprints < 5 s or < 15 m).
- **Top speed:** GPS Doppler speed where accurate, else derived; 3-point median to drop spikes.
- **Storage:** JSON on device: `runs/<id>.json` (full run) plus `index.json` of summaries
  (best efforts and sprint stats precomputed). In-progress run autosaved every 15 s and
  recovered on next launch.
- **Health:** `HKWorkoutBuilder` (running, outdoor, pause/resume events, distance and step
  samples) + `HKWorkoutRouteBuilder`.
- **Live Activity:** updated at most every 5 s plus on state changes; timer rendered with
  `Text(timerInterval:)` so it ticks without updates.
- **CI:** XcodeGen → unsigned archive → ad-hoc signed with entitlements (so the re-signing tool
  sees HealthKit) → `Paqo.ipa` uploaded as a workflow artifact.

## Left to the builder

Exact thresholds (tuned later with real runs), visual details within the agreed look, app icon.
