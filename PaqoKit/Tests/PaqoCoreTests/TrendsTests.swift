import Foundation
import XCTest
@testable import PaqoCore

final class TrendsTests: XCTestCase {
    let calendar = utcCalendar()
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 12))! }

    func day(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 8))!
    }

    func summary(_ date: Date, distance: Double = 3000, sprintDistance: Double = 0, sprintTime: Double = 0, sprints: Int = 0) -> RunSummary {
        var summary = RunSummary(run: Run(name: "x", startDate: date, endDate: date.addingTimeInterval(1200), distance: distance, movingTime: 1200))
        summary.sprintStats.sprintCount = sprints
        summary.sprintStats.totalSprintDistance = sprintDistance
        summary.sprintStats.totalSprintTime = sprintTime
        return summary
    }

    func testFourWeeksHasFourWeeklyBuckets() {
        let series = TrendCalculator.series(.distance, range: .fourWeeks, summaries: [], now: now, calendar: calendar)
        XCTAssertEqual(series.buckets.count, 4)
        for bucket in series.buckets {
            XCTAssertEqual(calendar.component(.weekday, from: bucket.start), 2) // Monday
        }
        XCTAssertEqual(series.buckets.map(\.start), series.buckets.map(\.start).sorted())
        XCTAssertEqual(series.buckets.last?.start, calendar.date(from: DateComponents(year: 2026, month: 11, day: 16)))
    }

    func testOneYearHasTwelveMonthlyBuckets() {
        let series = TrendCalculator.series(.runCount, range: .oneYear, summaries: [], now: now, calendar: calendar)
        XCTAssertEqual(series.buckets.count, 12)
        XCTAssertEqual(series.buckets.last?.start, calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        XCTAssertEqual(series.buckets.first?.start, calendar.date(from: DateComponents(year: 2025, month: 12, day: 1)))
    }

    func testAverageSprintSpeedIsDistanceWeighted() {
        let runs = [
            summary(day(11, 16), sprintDistance: 100, sprintTime: 20, sprints: 1),
            summary(day(11, 17), sprintDistance: 300, sprintTime: 100, sprints: 3),
        ]
        let series = TrendCalculator.series(.averageSprintSpeed, range: .fourWeeks, summaries: runs, now: now, calendar: calendar)
        XCTAssertEqual(series.buckets.last?.value ?? 0, 400.0 / 120, accuracy: 1e-9)
        XCTAssertEqual(series.buckets.last?.runCount, 2)
        XCTAssertNil(series.buckets.first?.value)
    }

    func testHeadlineAndPrevious() {
        let runs = [summary(day(11, 17), distance: 5000), summary(day(10, 10), distance: 4000)]
        let series = TrendCalculator.series(.distance, range: .fourWeeks, summaries: runs, now: now, calendar: calendar)
        XCTAssertEqual(series.headline, 5000)
        XCTAssertEqual(series.previous, 4000)
        let all = TrendCalculator.series(.distance, range: .all, summaries: runs, now: now, calendar: calendar)
        XCTAssertEqual(all.buckets.count, 2) // October and November
        XCTAssertEqual(all.headline, 9000)
        XCTAssertNil(all.previous)
    }

    func testMetricWithoutDataIsNil() {
        let runs = [summary(day(11, 17), sprintDistance: 100, sprintTime: 20, sprints: 1)]
        let series = TrendCalculator.series(.sprintCadence, range: .fourWeeks, summaries: runs, now: now, calendar: calendar)
        XCTAssertTrue(series.buckets.allSatisfy { $0.value == nil })
        XCTAssertNil(series.headline)
    }
}
