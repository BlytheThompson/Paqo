import Foundation

public enum TrendRange: String, CaseIterable, Sendable, Identifiable {
    case fourWeeks, threeMonths, oneYear, all

    public var id: String { rawValue }

    public var shortName: String {
        switch self {
        case .fourWeeks: return "4W"
        case .threeMonths: return "3M"
        case .oneYear: return "1Y"
        case .all: return "All"
        }
    }

    var bucketPeriod: PeriodKind {
        switch self {
        case .fourWeeks, .threeMonths: return .week
        case .oneYear, .all: return .month
        }
    }
}

public enum TrendMetric: String, CaseIterable, Sendable, Identifiable {
    case distance, runCount, averageSprintSpeed, peakSpeed, sprintsPerRun, averageSprintTime
    case averageSprintDistance, averageRest, workRestRatio, sprintShare, fade, sprintCadence

    public var id: String { rawValue }

    /// For rest and fade, lower (or less negative for fade) is better; everything
    /// else, higher is better.
    public var higherIsBetter: Bool {
        switch self {
        case .averageRest: return false
        default: return true
        }
    }
}

public struct TrendBucket: Hashable, Sendable, Identifiable {
    public var start: Date
    public var value: Double?
    public var runCount: Int
    public var id: Date { start }
}

public struct TrendSeries: Hashable, Sendable {
    public var metric: TrendMetric
    public var range: TrendRange
    /// Oldest first.
    public var buckets: [TrendBucket]
    /// The metric over the whole range.
    public var headline: Double?
    /// The metric over the same length of time just before the range (nil for All).
    public var previous: Double?
}

public enum TrendCalculator {
    public static func series(
        _ metric: TrendMetric,
        range: TrendRange,
        summaries: [RunSummary],
        now: Date,
        calendar: Calendar
    ) -> TrendSeries {
        let period = range.bucketPeriod
        let component = period.component
        let current = Stats.periodStart(for: now, period: period, calendar: calendar)

        let count: Int
        switch range {
        case .fourWeeks: count = 4
        case .threeMonths: count = 13
        case .oneYear: count = 12
        case .all:
            if let first = summaries.map(\.startDate).min() {
                let firstStart = Stats.periodStart(for: first, period: period, calendar: calendar)
                let months = calendar.dateComponents([.month], from: firstStart, to: current).month ?? 0
                count = max(1, months + 1)
            } else {
                count = 1
            }
        }

        let starts: [Date] = (0..<count).compactMap { i in
            calendar.date(byAdding: component, value: i - (count - 1), to: current)
        }
        guard let rangeStart = starts.first,
              let rangeEnd = calendar.date(byAdding: component, value: 1, to: current) else {
            return TrendSeries(metric: metric, range: range, buckets: [], headline: nil, previous: nil)
        }

        func runs(from start: Date, to end: Date) -> [RunSummary] {
            summaries.filter { $0.startDate >= start && $0.startDate < end }
        }

        var buckets: [TrendBucket] = []
        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] : rangeEnd
            let inBucket = runs(from: start, to: end)
            buckets.append(TrendBucket(start: start, value: aggregate(metric, inBucket), runCount: inBucket.count))
        }

        var previous: Double?
        if range != .all, let previousStart = calendar.date(byAdding: component, value: -count, to: rangeStart) {
            previous = aggregate(metric, runs(from: previousStart, to: rangeStart))
        }

        return TrendSeries(
            metric: metric,
            range: range,
            buckets: buckets,
            headline: aggregate(metric, runs(from: rangeStart, to: rangeEnd)),
            previous: previous
        )
    }

    /// The metric over a set of runs; nil when none of them has data for it.
    public static func aggregate(_ metric: TrendMetric, _ runs: [RunSummary]) -> Double? {
        guard !runs.isEmpty else { return nil }
        let sprinted = runs.filter { $0.sprintStats.sprintCount > 0 }
        let sprintTime = sprinted.reduce(0) { $0 + $1.sprintStats.totalSprintTime }
        let sprintDistance = sprinted.reduce(0) { $0 + $1.sprintStats.totalSprintDistance }
        let sprints = sprinted.reduce(0) { $0 + $1.sprintStats.sprintCount }

        func mean(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }

        switch metric {
        case .distance:
            return runs.reduce(0) { $0 + $1.distance }
        case .runCount:
            return Double(runs.count)
        case .averageSprintSpeed:
            return sprintTime > 0 ? sprintDistance / sprintTime : nil
        case .peakSpeed:
            return sprinted.isEmpty ? nil : sprinted.map(\.sprintStats.peakSpeed).max()
        case .sprintsPerRun:
            return Double(sprints) / Double(runs.count)
        case .averageSprintTime:
            return sprints > 0 ? sprintTime / Double(sprints) : nil
        case .averageSprintDistance:
            return sprints > 0 ? sprintDistance / Double(sprints) : nil
        case .averageRest:
            return mean(runs.compactMap(\.sprintStats.averageRest))
        case .workRestRatio:
            let rested = runs.filter { $0.sprintStats.averageRest != nil && $0.sprintStats.sprintCount > 1 }
            let work = rested.reduce(0) { $0 + $1.sprintStats.totalSprintTime }
            let rest = rested.reduce(0) { $0 + ($1.sprintStats.averageRest ?? 0) * Double($1.sprintStats.sprintCount - 1) }
            return rest > 0 ? work / rest : nil
        case .sprintShare:
            let moving = runs.reduce(0) { $0 + $1.movingTime }
            return moving > 0 ? runs.reduce(0) { $0 + $1.sprintStats.totalSprintTime } / moving : nil
        case .fade:
            return mean(runs.compactMap(\.sprintStats.fade))
        case .sprintCadence:
            return mean(runs.compactMap(\.sprintStats.averageSprintCadence))
        }
    }
}
