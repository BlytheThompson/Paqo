import MapKit
import PaqoCore
import SwiftUI

/// Map first: the route draws in above, stats and controls below.
struct LiveRunView: View {
    @Environment(RunController.self) private var controller
    @AppStorage(SettingsKey.unit) private var unit: DistanceUnit = .localeDefault
    @State private var camera: MapCameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
    @State private var confirmEnd = false

    var body: some View {
        let s = controller.snapshot
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Map(position: $camera) {
                    ForEach(controller.routePieces) { piece in
                        MapPolyline(coordinates: piece.points.map(\.clCoordinate))
                            .stroke(piece.color, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    }
                    UserAnnotation()
                }
                .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }

                SegmentChip(
                    kind: s?.segmentKind,
                    number: s?.segmentNumber ?? 0,
                    duration: s?.segmentDuration ?? 0,
                    isPaused: controller.isPaused
                )
                .padding(.top, 12)
            }

            statsPanel(s)
        }
        .background(Theme.background.ignoresSafeArea())
        .confirmationDialog("End this run?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End & Save") { controller.finish() }
            Button("Discard Run", role: .destructive) { controller.discard() }
            Button("Keep Going", role: .cancel) {}
        }
    }

    private func statsPanel(_ s: LiveSnapshot?) -> some View {
        VStack(spacing: 22) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 18) {
                GridRow {
                    StatBlock(value: Format.duration(s?.movingTime ?? 0), label: "Time", size: 44)
                    StatBlock(value: Format.distance(s?.distance ?? 0, unit: unit), unit: unit.abbreviation, label: "Distance", size: 44)
                }
                GridRow {
                    StatBlock(value: Format.pace(secondsPerMeter: s?.currentPace, unit: unit), unit: unit.paceSuffix, label: "Pace now", size: 30)
                    StatBlock(value: Format.pace(secondsPerMeter: s?.averagePace, unit: unit), unit: unit.paceSuffix, label: "Avg pace", size: 30)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 14) {
                Button {
                    controller.togglePause()
                } label: {
                    Label(controller.isPaused ? "Resume" : "Pause", systemImage: controller.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 18, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .foregroundStyle(Theme.background)
                        .background(Theme.accent, in: Capsule())
                }
                Button {
                    confirmEnd = true
                } label: {
                    Label("End", systemImage: "stop.fill")
                        .font(.system(size: 18, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .foregroundStyle(Theme.textPrimary)
                        .background(Theme.surfaceRaised, in: Capsule())
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .background(Theme.background)
    }
}
