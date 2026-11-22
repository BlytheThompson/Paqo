import CoreLocation
import MapKit
import PaqoCore
import SwiftUI

/// Every run drawn faintly on one map, so the streets run most often glow brightest.
/// "Sprints only" shows where the owner goes hard.
struct HeatmapView: View {
    enum Window: String, CaseIterable, Identifiable {
        case all, year, threeMonths
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .year: return "1Y"
            case .threeMonths: return "3M"
            }
        }
    }

    private struct Line: Identifiable {
        let id: String
        let points: [CLLocationCoordinate2D]
    }

    @Environment(RunLibrary.self) private var library
    @State private var routes: [HeatmapRoute]?
    @State private var sprintsOnly = false
    @State private var window: Window = .all
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        let lines = makeLines()
        ZStack(alignment: .top) {
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                ForEach(lines) { line in
                    MapPolyline(coordinates: line.points)
                        .stroke(Theme.accent.opacity(0.18), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))

            HStack(spacing: 12) {
                Picker("Range", selection: $window) {
                    ForEach(Window.allCases) { window in
                        Text(window.title).tag(window)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 170)
                Spacer()
                Toggle("Sprints only", isOn: $sprintsOnly)
                    .toggleStyle(.button)
                    .tint(Theme.accent)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(12)

            if routes == nil {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lines.isEmpty {
                Text(sprintsOnly ? "No sprints in this range" : "No routes in this range")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: library.summaries.count) {
            routes = await library.heatmapRoutes()
        }
        .onChange(of: window) { _, _ in camera = .automatic }
        .onChange(of: sprintsOnly) { _, _ in camera = .automatic }
    }

    private func makeLines() -> [Line] {
        guard let routes else { return [] }
        let cutoff: Date?
        switch window {
        case .all: cutoff = nil
        case .year: cutoff = Calendar.current.date(byAdding: .year, value: -1, to: Date())
        case .threeMonths: cutoff = Calendar.current.date(byAdding: .month, value: -3, to: Date())
        }
        var lines: [Line] = []
        for route in routes where cutoff.map({ route.startDate >= $0 }) ?? true {
            for (index, piece) in route.pieces.enumerated() where piece.points.count > 1 {
                if sprintsOnly && piece.kind != .sprint { continue }
                lines.append(Line(id: "\(route.id.uuidString)-\(index)", points: piece.points.map(\.clCoordinate)))
            }
        }
        return lines
    }
}
