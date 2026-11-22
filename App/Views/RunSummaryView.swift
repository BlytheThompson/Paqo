import Charts
import MapKit
import PaqoCore
import SwiftUI

/// Everything about one run: coloured route, headline numbers, sprints, splits, charts.
struct RunSummaryView: View {
    @Environment(RunLibrary.self) private var library
    @Environment(RunController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.unit) private var unit: DistanceUnit = .localeDefault

    @State private var run: Run
    private let justFinished: Bool
    private let onDone: (() -> Void)?
    private let pieces: [RoutePiece]
    private let profile: [ProfilePoint]

    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    init(run: Run, justFinished: Bool = false, onDone: (() -> Void)? = nil) {
        _run = State(initialValue: run)
        self.justFinished = justFinished
        self.onDone = onDone
        pieces = RouteBuilder.pieces(track: run.track, segments: run.segments)
        profile = ProfileBuilder.profile(for: run)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RouteMapView(pieces: pieces, start: run.track.first?.coordinate, end: run.track.last?.coordinate)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                titleBlock
                headline
                healthBanner
                if !run.sprints.isEmpty { sprintHighlights }
                SplitsSection(run: run, unit: unit)
                if profile.contains(where: { $0.pace != nil }) {
                    PaceChart(profile: profile, segments: run.segments, track: run.track, unit: unit)
                }
                if profile.contains(where: { $0.altitude != nil }) {
                    ElevationChart(profile: profile, gain: run.elevationGain, loss: run.elevationLoss, unit: unit)
                }
                if !run.sprints.isEmpty { SprintList(run: run, unit: unit) }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(justFinished ? "Run Complete" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }
                        .fontWeight(.semibold)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        newName = run.name
                        renaming = true
                    } label: { Label("Rename", systemImage: "pencil") }
                    if !run.savedToHealth {
                        Button {
                            Task {
                                if await controller.saveToHealth(run) { run.savedToHealth = true }
                            }
                        } label: { Label("Save to Apple Health", systemImage: "heart") }
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: { Label("Delete Run", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename Run", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                library.rename(id: run.id, to: newName)
                if let updated = library.loadRun(id: run.id) { run = updated }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this run?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Run", role: .destructive) {
                library.delete(id: run.id)
                if let onDone { onDone() } else { dismiss() }
            }
        } message: {
            Text("It will be removed from Paqo. Anything saved to Apple Health stays there.")
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(run.name)
                .font(.system(size: 28, weight: .bold))
            Text(run.startDate.formatted(date: .complete, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 4)
    }

    private var headline: some View {
        Card {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 18) {
                GridRow {
                    StatBlock(value: Format.distance(run.distance, unit: unit), unit: unit.abbreviation, label: "Distance", size: 34)
                    StatBlock(value: Format.duration(run.movingTime), label: "Moving time", size: 34)
                }
                GridRow {
                    StatBlock(value: Format.pace(secondsPerMeter: run.averagePace, unit: unit), unit: unit.paceSuffix, label: "Avg pace", size: 24)
                    StatBlock(value: Format.elevation(run.elevationGain, unit: unit), unit: unit.elevationAbbreviation, label: "Elevation gain", size: 24)
                }
                if run.pauses.count > 0 || run.averageCadence != nil {
                    GridRow {
                        StatBlock(value: Format.duration(run.elapsedTime), label: "Total time", size: 20)
                        if let cadence = run.averageCadence {
                            StatBlock(value: "\(Int(cadence.rounded()))", unit: "spm", label: "Cadence", size: 20)
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var healthBanner: some View {
        if justFinished {
            switch controller.healthStatus {
            case .saving:
                bannerRow(icon: "heart", text: "Saving to Apple Health…", color: Theme.textSecondary)
            case .saved:
                bannerRow(icon: "heart.fill", text: "Saved to Apple Health", color: Theme.accent)
            case .failed(let message):
                bannerRow(icon: "heart.slash", text: message, color: Theme.danger)
            case .idle, .off:
                EmptyView()
            }
        }
    }

    private func bannerRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.footnote).foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var sprintHighlights: some View {
        let sprints = run.sprints
        let longest = sprints.max { $0.distance < $1.distance }
        return Card {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
                GridRow {
                    StatBlock(value: "\(sprints.count)", label: sprints.count == 1 ? "Sprint" : "Sprints", size: 28)
                    StatBlock(value: Format.speed(run.topSpeed, unit: unit), unit: unit.speedAbbreviation, label: "Top speed", size: 28)
                }
                GridRow {
                    StatBlock(value: Format.distance(longest?.distance ?? 0, unit: unit), unit: unit.abbreviation, label: "Longest sprint", size: 20)
                    StatBlock(value: Format.duration(sprints.map(\.duration).max() ?? 0), label: "Longest sprint time", size: 20)
                }
            }
        }
    }
}

// MARK: - Route map

struct RouteMapView: View {
    let pieces: [RoutePiece]
    let start: Coordinate?
    let end: Coordinate?

    var body: some View {
        Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
            ForEach(pieces) { piece in
                MapPolyline(coordinates: piece.points.map(\.clCoordinate))
                    .stroke(piece.color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let start {
                Annotation("Start", coordinate: start.clCoordinate) {
                    Circle()
                        .fill(Theme.textPrimary)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Theme.background, lineWidth: 3))
                }
                .annotationTitles(.hidden)
            }
            if let end {
                Annotation("Finish", coordinate: end.clCoordinate) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Theme.background, lineWidth: 3))
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
    }
}

// MARK: - Splits

struct SplitsSection: View {
    let run: Run
    let unit: DistanceUnit

    var body: some View {
        let splits = SplitCalculator.splits(for: run.track, unitLength: unit.metersPerUnit)
        if !splits.isEmpty {
            let paces = splits.compactMap(\.pace)
            let fastest = paces.min() ?? 0
            let slowest = paces.max() ?? 1
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Splits")
                Card {
                    VStack(spacing: 12) {
                        ForEach(splits) { split in
                            HStack(spacing: 12) {
                                Text(split.isPartial ? Format.distance(split.distance, unit: unit) : "\(split.index)")
                                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 44, alignment: .leading)
                                Text(Format.pace(secondsPerMeter: split.pace, unit: unit))
                                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                                    .frame(width: 58, alignment: .leading)
                                GeometryReader { geo in
                                    let fraction = barFraction(split.pace, fastest: fastest, slowest: slowest)
                                    Capsule()
                                        .fill(split.pace == fastest ? Theme.accent : Theme.accent.opacity(0.35))
                                        .frame(width: max(8, geo.size.width * fraction))
                                }
                                .frame(height: 8)
                                if let change = split.elevationChange {
                                    Text("\(change >= 0 ? "↑" : "↓")\(Format.elevation(abs(change), unit: unit))")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Theme.textSecondary)
                                        .frame(width: 46, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Faster splits get longer bars.
    private func barFraction(_ pace: Double?, fastest: Double, slowest: Double) -> Double {
        guard let pace, slowest > fastest else { return 1 }
        return 1 - 0.7 * (pace - fastest) / (slowest - fastest)
    }
}

// MARK: - Charts

struct PaceChart: View {
    let profile: [ProfilePoint]
    let segments: [RunSegment]
    let track: [TrackPoint]
    let unit: DistanceUnit

    private struct Point: Identifiable {
        let id: Int
        let x: Double
        let y: Double
    }

    private struct Band: Identifiable {
        let id: Int
        let start: Double
        let end: Double
    }

    var body: some View {
        // Pace in seconds per unit; walking/standing capped at 30 min so sprints stay readable.
        let points: [Point] = profile.enumerated().compactMap { index, p in
            guard let pace = p.pace else { return nil }
            return Point(id: index, x: unit.distance(fromMeters: p.distance), y: min(unit.pace(fromSecondsPerMeter: pace), 1800))
        }
        let origin = track.first?.distance ?? 0
        let bands: [Band] = segments.enumerated().compactMap { index, s in
            guard s.kind == .sprint else { return nil }
            return Band(id: index, start: unit.distance(fromMeters: s.startDistance - origin), end: unit.distance(fromMeters: s.endDistance - origin))
        }
        let low = points.map(\.y).min() ?? 0
        let high = points.map(\.y).max() ?? 1

        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Pace")
            Card {
                Chart {
                    ForEach(bands) { band in
                        RectangleMark(
                            xStart: .value("Sprint start", band.start),
                            xEnd: .value("Sprint end", band.end),
                            yStart: .value("Low", low),
                            yEnd: .value("High", high)
                        )
                        .foregroundStyle(Theme.accentDim)
                    }
                    ForEach(points) { point in
                        LineMark(x: .value("Distance", point.x), y: .value("Pace", point.y))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false, reversed: true))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) {
                                Text(Format.duration(seconds)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisValueLabel {
                            if let d = value.as(Double.self) {
                                Text("\(Format.fixed(d, decimals: 1)) \(unit.abbreviation)").foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .frame(height: 180)
            }
        }
    }
}

struct ElevationChart: View {
    let profile: [ProfilePoint]
    let gain: Double
    let loss: Double
    let unit: DistanceUnit

    private struct Point: Identifiable {
        let id: Int
        let x: Double
        let y: Double
    }

    var body: some View {
        let points: [Point] = profile.enumerated().compactMap { index, p in
            guard let altitude = p.altitude else { return nil }
            return Point(id: index, x: unit.distance(fromMeters: p.distance), y: unit.elevation(fromMeters: altitude))
        }
        let low = points.map(\.y).min() ?? 0
        let high = points.map(\.y).max() ?? 1
        let pad = max(3, (high - low) * 0.15)
        let base = low - pad

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Elevation")
                Spacer()
                Text("↑\(Format.elevation(gain, unit: unit))  ↓\(Format.elevation(loss, unit: unit)) \(unit.elevationAbbreviation)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 8)
            }
            Card {
                Chart {
                    ForEach(points) { point in
                        AreaMark(
                            x: .value("Distance", point.x),
                            yStart: .value("Base", base),
                            yEnd: .value("Elevation", point.y)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(x: .value("Distance", point.x), y: .value("Elevation", point.y))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .chartYScale(domain: base...(high + pad))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text("\(Int(v.rounded()))").foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisValueLabel {
                            if let d = value.as(Double.self) {
                                Text("\(Format.fixed(d, decimals: 1)) \(unit.abbreviation)").foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                .frame(height: 140)
            }
        }
    }
}

// MARK: - Sprint list

struct SprintList: View {
    let run: Run
    let unit: DistanceUnit

    private struct Row: Identifiable {
        let id: Int
        let number: Int
        let sprint: RunSegment
        let walkAfter: RunSegment?
    }

    var body: some View {
        let rows = makeRows()
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Sprints")
            Card {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(row.number)")
                                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 26, alignment: .leading)
                                Text("\(Format.distance(row.sprint.distance, unit: unit)) \(unit.abbreviation)")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(Format.duration(row.sprint.duration))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(Format.speed(row.sprint.topSpeed, unit: unit)) \(unit.speedAbbreviation)")
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .font(.system(size: 16, weight: .semibold).monospacedDigit())
                            if let walk = row.walkAfter {
                                Text("then walked \(Format.duration(walk.duration)) · \(Format.distance(walk.distance, unit: unit)) \(unit.abbreviation)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.leading, 26)
                            }
                        }
                        .padding(.vertical, 10)
                        if row.id != rows.last?.id {
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
            }
        }
    }

    private func makeRows() -> [Row] {
        var rows: [Row] = []
        var number = 0
        for (index, segment) in run.segments.enumerated() where segment.kind == .sprint {
            number += 1
            let next = index + 1 < run.segments.count ? run.segments[index + 1] : nil
            rows.append(Row(id: index, number: number, sprint: segment, walkAfter: next?.kind == .walk ? next : nil))
        }
        return rows
    }
}
