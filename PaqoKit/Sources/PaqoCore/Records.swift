import Foundation

public enum PeriodKind: String, CaseIterable, Sendable, Identifiable {
    case week, month, year

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }
}

public struct PeriodTotal: Hashable, Sendable, Identifiable {
    public var start: Date
    public var end: Date
    /// Meters.
    public var distance: Double
    public var movingTime: TimeInterval
    public var runCount: Int
    public var id: Date { start }
}

public enum Stats {
    public static func periodStart(for date: Date, period: PeriodKind, calendar: Calendar) -> Date {
        calendar.dateInterval(of: period.component, for: date)?.start ?? date
    }

    /// Totals for the last `count` periods, oldest first; the last element is the
    /// period containing `now`. Empty periods are included (for charts).
    public static func totals(
        for runs: [RunSummary],
        period: PeriodKind,
        count: Int,
        now: Date,
        calendar: Calendar
    ) -> [PeriodTotal] {
        guard count > 0, let current = calendar.dateInterval(of: period.component, for: now) else { return [] }
        var result: [PeriodTotal] = []
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: period.component, value: -offset, to: current.start),
                  let interval = calendar.dateInterval(of: period.component, for: start) else { continue }
            let inPeriod = runs.filter { $0.startDate >= interval.start && $0.startDate < interval.end }
            result.append(PeriodTotal(
                start: interval.start,
                end: interval.end,
                distance: inPeriod.reduce(0) { $0 + $1.distance },
                movingTime: inPeriod.reduce(0) { $0 + $1.movingTime },
                runCount: inPeriod.count
            ))
        }
        return result
    }
}

public struct RecordEntry: Hashable, Sendable {
    public var value: Double
    /// The run that set it; nil for weekly/monthly aggregates.
    public var runID: UUID?
    public var date: Date

    public init(value: Double, runID: UUID?, date: Date) {
        self.value = value
        self.runID = runID
        self.date = date
    }
}

public struct FastestRecord: Hashable, Sendable, Identifiable {
    public var distance: EffortDistance
    /// value = seconds.
    public var entry: RecordEntry
    public var id: Double { distance.meters }
}

public struct PersonalRecords: Sendable, Equatable {
    public var fastest: [FastestRecord] = []
    /// Meters.
    public var longestDistance: RecordEntry?
    /// Seconds.
    public var longestDuration: RecordEntry?
    /// m/s.
    public var topSpeed: RecordEntry?
    /// Meters.
    public var longestSprintDistance: RecordEntry?
    /// Seconds.
    public var longestSprintDuration: RecordEntry?
    public var mostSprints: RecordEntry?
    /// m/s: fastest average speed of a sprint lasting at least 10 s.
    public var fastestSprint: RecordEntry?
    /// Consecutive weeks with at least one run, counting this week or last week.
    public var currentWeekStreak: Int = 0
    public var longestWeekStreak: Int = 0
    /// Meters; date is the week's start.
    public var biggestWeek: RecordEntry?
    /// Meters; date is the month's start.
    public var biggestMonth: RecordEntry?

    public init() {}

    public var isEmpty: Bool { longestDistance == nil }

    public static func compute(from runs: [RunSummary], now: Date, calendar: Calendar) -> PersonalRecords {
        var records = PersonalRecords()
        guard !runs.isEmpty else { return records }
        // Oldest first so ties go to the run that set the record first.
        let ordered = runs.sorted { $0.startDate < $1.startDate }

        func best(_ value: (RunSummary) -> Double?, lowerIsBetter: Bool = false) -> RecordEntry? {
            var result: RecordEntry?
            for run in ordered {
                guard let v = value(run), v > 0 else { continue }
                if let current = result {
                    if lowerIsBetter ? v < current.value : v > current.value {
                        result = RecordEntry(value: v, runID: run.id, date: run.startDate)
                    }
                } else {
                    result = RecordEntry(value: v, runID: run.id, date: run.startDate)
                }
            }
            return result
        }

        records.fastest = EffortDistance.standard.compactMap { effort in
            best({ $0.bestEffort(for: effort.meters) }, lowerIsBetter: true)
                .map { FastestRecord(distance: effort, entry: $0) }
        }
        records.longestDistance = best { $0.distance }
        records.longestDuration = best { $0.movingTime }
        records.topSpeed = best { $0.topSpeed }
        records.longestSprintDistance = best { $0.longestSprintDistance }
        records.longestSprintDuration = best { $0.longestSprintDuration }
        records.mostSprints = best { Double($0.sprintCount) }
        records.fastestSprint = best { $0.sprintStats.fastestTenSecondSprintSpeed }

        // Weekly and monthly aggregates.
        var weekTotals: [Date: Double] = [:]
        var monthTotals: [Date: Double] = [:]
        for run in ordered {
            weekTotals[Stats.periodStart(for: run.startDate, period: .week, calendar: calendar), default: 0] += run.distance
            monthTotals[Stats.periodStart(for: run.startDate, period: .month, calendar: calendar), default: 0] += run.distance
        }
        records.biggestWeek = weekTotals
            .filter { $0.value > 0 }
            .max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }
            .map { RecordEntry(value: $0.value, runID: nil, date: $0.key) }
        records.biggestMonth = monthTotals
            .filter { $0.value > 0 }
            .max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }
            .map { RecordEntry(value: $0.value, runID: nil, date: $0.key) }

        // Streaks of consecutive weeks.
        let weeks = Set(weekTotals.keys)
        let sortedWeeks = weeks.sorted()
        var longest = 0
        var run = 0
        var previous: Date?
        for week in sortedWeeks {
            if let previous, calendar.date(byAdding: .weekOfYear, value: 1, to: previous) == week {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = week
        }
        records.longestWeekStreak = longest

        let thisWeek = Stats.periodStart(for: now, period: .week, calendar: calendar)
        var cursor: Date? = weeks.contains(thisWeek)
            ? thisWeek
            : calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek)
        var current = 0
        while let week = cursor, weeks.contains(week) {
            current += 1
            cursor = calendar.date(byAdding: .weekOfYear, value: -1, to: week)
        }
        records.currentWeekStreak = current

        return records
    }
}
