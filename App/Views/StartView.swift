import PaqoCore
import SwiftUI

struct StartView: View {
    @Environment(RunController.self) private var controller
    @Environment(RunLibrary.self) private var library
    @Environment(\.openURL) private var openURL
    @AppStorage(SettingsKey.unit) private var unit: DistanceUnit = .localeDefault

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.top, 12)

                Spacer()

                startButton

                GPSIndicator(accuracy: controller.gpsAccuracy)
                    .padding(.top, 28)

                if let problem = controller.permissionProblem {
                    VStack(spacing: 10) {
                        Text(problem)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .font(.footnote.weight(.semibold))
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 16)
                }

                Spacer()

                if let recovered = controller.recoveredRun {
                    recoveredBanner(recovered)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
            }
        }
        .onAppear { controller.warmUpGPS() }
        .onDisappear { controller.coolDownGPS() }
    }

    private var header: some View {
        let week = library.totals(.week, count: 1).last
        return HStack(alignment: .bottom) {
            Text("paqo")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Format.distance(week?.distance ?? 0, unit: unit)) \(unit.abbreviation)")
                    .font(Theme.number(20))
                    .foregroundStyle(Theme.textPrimary)
                Text("THIS WEEK")
                    .font(Theme.label)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var startButton: some View {
        Button {
            controller.startTapped()
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.08))
                    .frame(width: 260, height: 260)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 210, height: 210)
                    .shadow(color: Theme.accent.opacity(0.45), radius: 30)
                if controller.phase == .preparing {
                    ProgressView()
                        .tint(Theme.background)
                        .scaleEffect(1.6)
                } else {
                    Text("START")
                        .font(.system(size: 30, weight: .heavy).width(.expanded))
                        .foregroundStyle(Theme.background)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(controller.phase != .idle)
        .accessibilityLabel("Start run")
    }

    private func recoveredBanner(_ run: Run) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recovered your last run")
                    .font(.subheadline.weight(.semibold))
                Text("\(Format.distance(run.distance, unit: unit)) \(unit.abbreviation) · \(Format.duration(run.movingTime)) — saved to History")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button {
                controller.recoveredRun = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct CountdownView: View {
    let number: Int
    @Environment(RunController.self) private var controller

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack {
                Spacer()
                Text("\(number)")
                    .font(.system(size: 180, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: number)
                Text("Get ready")
                    .font(Theme.label)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Cancel") { controller.cancelCountdown() }
                    .font(.headline)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.bottom, 40)
            }
        }
    }
}
