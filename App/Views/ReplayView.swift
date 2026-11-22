import MapKit
import PaqoCore
import SwiftUI

/// Plays a run back on the map: a marker runs the route, the line fills in mint
/// (sprints) and grey (walks), and the numbers update as it goes.
struct ReplayView: View {
    let run: Run
    let unit: DistanceUnit

    @Environment(\.dismiss) private var dismiss
    @State private var timeline: ReplayTimeline
    @State private var fullRoute: [RoutePiece]
    @State private var time: TimeInterval = 0
    @State private var playing = false
    @State private var speed: Double = 30
    @State private var follow = true
    @State private var camera: MapCameraPosition = .automatic
    @State private var lastFrame: Date?

    private static let speeds: [Double] = [10, 30, 60]

    init(run: Run, unit: DistanceUnit) {
        self.run = run
        self.unit = unit
        _timeline = State(initialValue: ReplayTimeline(run: run))
        _fullRoute = State(initialValue: RouteBuilder.pieces(track: run.track, segments: run.segments))
    }

    var body: some View {
        let state = timeline.state(at: time)
        let trail = timeline.trail(upTo: time)
        ZStack(alignment: .bottom) {
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                ForEach(fullRoute) { piece in
                    MapPolyline(coordinates: piece.points.map(\.clCoordinate))
                        .stroke(Theme.textSecondary.opacity(0.25), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                ForEach(trail) { piece in
                    MapPolyline(coordinates: piece.points.map(\.clCoordinate))
                        .stroke(piece.color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                if let coordinate = state.coordinate {
                    Annotation("Runner", coordinate: coordinate.clCoordinate) {
                        Circle()
                            .fill(state.segmentKind == .sprint ? Theme.accent : Theme.textPrimary)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Theme.background, lineWidth: 3))
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .ignoresSafeArea()

            controls(state)
                .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .top) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Close replay")
                Spacer()
                Button {
                    follow.toggle()
                    updateCamera()
                } label: {
                    Label(follow ? "Following" : "Overview", systemImage: follow ? "location.fill" : "map")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
        }
        .background {
            if playing {
                TimelineView(.animation) { context in
                    Color.clear
                        .onChange(of: context.date) { _, now in advance(to: now) }
                }
            }
        }
        .onChange(of: time) { _, _ in
            if follow { updateCamera() }
        }
        .onAppear(perform: updateCamera)
    }

    private func controls(_ state: ReplayState) -> some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                StatBlock(value: Format.duration(state.activeTime), label: "Time", size: 26)
                Spacer()
                StatBlock(value: Format.distance(state.distance, unit: unit), unit: unit.abbreviation, label: "Distance", size: 26)
                Spacer()
                StatBlock(value: Format.speed(state.speed, unit: unit), unit: unit.speedAbbreviation, label: "Speed", size: 26)
            }
            HStack {
                SegmentChip(kind: state.segmentKind, number: state.segmentNumber, duration: state.segmentElapsed, isPaused: false)
                Spacer()
                Text("\(Format.pace(secondsPerMeter: state.speed > 0.3 ? 1 / state.speed : nil, unit: unit)) \(unit.paceSuffix)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            Slider(value: $time, in: 0...max(1, timeline.duration))
                .tint(Theme.accent)
            HStack(spacing: 16) {
                Button {
                    togglePlay()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                        .background(Theme.accent, in: Circle())
                        .foregroundStyle(Theme.background)
                }
                .accessibilityLabel(playing ? "Pause" : "Play")
                Picker("Speed", selection: $speed) {
                    ForEach(Self.speeds, id: \.self) { value in
                        Text("\(Int(value))×").tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(16)
        .background(Theme.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func togglePlay() {
        if !playing && time >= timeline.duration { time = 0 }
        playing.toggle()
        lastFrame = nil
    }

    private func advance(to now: Date) {
        defer { lastFrame = now }
        guard let last = lastFrame else { return }
        let next = time + now.timeIntervalSince(last) * speed
        if next >= timeline.duration {
            time = timeline.duration
            playing = false
        } else {
            time = next
        }
    }

    private func updateCamera() {
        guard follow else {
            camera = .automatic
            return
        }
        guard let coordinate = timeline.state(at: time).coordinate else { return }
        camera = .camera(MapCamera(centerCoordinate: coordinate.clCoordinate, distance: 700))
    }
}
