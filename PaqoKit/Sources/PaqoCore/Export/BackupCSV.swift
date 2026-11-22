import Foundation

/// Rows for `runs.csv` and `sprints.csv`: raw metric values (m, s, m/s) for
/// spreadsheets and scripts, plus formatted columns in the owner's unit for people.
public enum BackupCSV {
    static func unitSuffix(_ unit: DistanceUnit) -> String { unit == .miles ? "mi" : "km" }
    static func speedSuffix(_ unit: DistanceUnit) -> String { unit == .miles ? "mph" : "kmh" }

    public static func runsHeader(unit: DistanceUnit) -> [String] {
        let u = unitSuffix(unit), s = speedSuffix(unit)
        return [
            "run_id", "name", "start_local", "start_utc", "distance_m", "distance_\(u)",
            "moving_time_s", "moving_time", "elapsed_time_s", "avg_pace_per_\(u)", "avg_speed_mps",
            "elevation_gain_m", "elevation_loss_m", "steps", "avg_cadence_spm", "sprint_count",
            "sprint_time_s", "sprint_distance_m", "sprint_share_pct", "avg_sprint_speed_mps",
            "avg_sprint_speed_\(s)", "peak_speed_mps", "peak_speed_\(s)", "avg_rest_s",
            "work_rest_ratio", "run_fade_pct", "saved_to_health", "engine_version",
        ]
    }

    public static func runRow(_ run: Run, unit: DistanceUnit, timeZone: TimeZone) -> [String] {
        let stats = SprintAnalyzer.stats(for: run)
        let peak = stats.sprintCount > 0
            ? stats.peakSpeed
            : (run.track.count > 1 ? TrackMath.peakSpeed(in: run.track, from: 0, to: run.movingTime).speed : run.topSpeed)
        let averageSpeed = run.movingTime > 0 ? run.distance / run.movingTime : 0
        return [
            run.id.uuidString,
            run.name,
            localTime(run.startDate, timeZone),
            ISO8601.string(from: run.startDate),
            raw(run.distance),
            Format.distance(run.distance, unit: unit),
            raw(run.movingTime),
            Format.duration(run.movingTime),
            raw(run.elapsedTime),
            Format.pace(secondsPerMeter: run.averagePace, unit: unit),
            raw(averageSpeed),
            raw(run.elevationGain),
            raw(run.elevationLoss),
            run.steps.map { "\($0)" } ?? "",
            run.averageCadence.map { Format.fixed($0, decimals: 1) } ?? "",
            "\(stats.sprintCount)",
            raw(stats.totalSprintTime),
            raw(stats.totalSprintDistance),
            Format.fixed(stats.sprintShare * 100, decimals: 1),
            raw(stats.averageSprintSpeed),
            Format.speed(stats.averageSprintSpeed, unit: unit),
            raw(peak),
            Format.speed(peak, unit: unit),
            stats.averageRest.map(raw) ?? "",
            stats.workRestRatio.map(raw) ?? "",
            stats.fade.map { Format.fixed($0 * 100, decimals: 1) } ?? "",
            run.savedToHealth ? "true" : "false",
            run.engineVersion.map { "\($0)" } ?? "",
        ]
    }

    public static func sprintsHeader(unit: DistanceUnit) -> [String] {
        let u = unitSuffix(unit), s = speedSuffix(unit)
        return [
            "run_id", "run_name", "run_start_local", "sprint_number", "start_s", "duration_s",
            "duration", "distance_m", "distance_\(u)", "avg_speed_mps", "avg_speed_\(s)",
            "avg_pace_per_\(u)", "peak_speed_mps", "peak_speed_\(s)", "time_to_peak_s",
            "avg_cadence_spm", "climb_m", "rest_after_s", "rest_after_distance_m", "in_sprint_fade_pct",
        ]
    }

    public static func sprintRows(_ run: Run, unit: DistanceUnit, timeZone: TimeZone) -> [[String]] {
        let start = localTime(run.startDate, timeZone)
        return SprintAnalyzer.details(for: run).map { d in
            [
                run.id.uuidString,
                run.name,
                start,
                "\(d.number)",
                raw(d.segment.startTime),
                raw(d.segment.duration),
                Format.duration(d.segment.duration),
                raw(d.segment.distance),
                Format.distance(d.segment.distance, unit: unit, decimals: 3),
                raw(d.averageSpeed),
                Format.speed(d.averageSpeed, unit: unit),
                Format.pace(secondsPerMeter: d.averagePace, unit: unit),
                raw(d.peakSpeed),
                Format.speed(d.peakSpeed, unit: unit),
                raw(d.timeToPeak),
                d.averageCadence.map { Format.fixed($0, decimals: 1) } ?? "",
                raw(d.climb),
                d.restAfter.map { raw($0.duration) } ?? "",
                d.restAfter.map { raw($0.distance) } ?? "",
                d.inSprintFade.map { Format.fixed($0 * 100, decimals: 1) } ?? "",
            ]
        }
    }

    static func raw(_ value: Double) -> String {
        Format.fixed(value, decimals: 3)
    }

    /// "2026-11-22 07:12:03" in the given time zone.
    static func localTime(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
