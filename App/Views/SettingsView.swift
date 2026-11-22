import CoreLocation
import CoreMotion
import PaqoCore
import PaqoSensors
import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.unit) private var unit: DistanceUnit = .localeDefault
    @AppStorage(SettingsKey.saveToHealth) private var saveToHealth = true
    @Environment(\.openURL) private var openURL
    @State private var locationStatus = CLLocationManager().authorizationStatus
    @State private var motionStatus = MotionService.authorizationStatus

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Units", selection: $unit) {
                        ForEach(DistanceUnit.allCases) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Theme.surface)
                } header: {
                    Text("Units")
                } footer: {
                    Text("Distance in \(unit.abbreviation), pace per \(unit.abbreviation), sprint speed in \(unit.speedAbbreviation), elevation in \(unit.elevationAbbreviation).")
                }

                Section {
                    Toggle("Save runs to Apple Health", isOn: $saveToHealth)
                        .listRowBackground(Theme.surface)
                } footer: {
                    Text("Each finished run is saved as a running workout with its route.")
                }

                Section("Permissions") {
                    permissionRow("Location", granted: locationGranted, detail: locationDetail)
                    permissionRow("Motion & Fitness", granted: motionStatus == .authorized, detail: motionDetail)
                    Button("Open iPhone Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .listRowBackground(Theme.surface)
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(version).foregroundStyle(Theme.textSecondary)
                    }
                    .listRowBackground(Theme.surface)
                    Text("Paqo is free. No accounts, no ads, no paywalls. Your runs stay on your phone.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .listRowBackground(Theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .onAppear {
                locationStatus = CLLocationManager().authorizationStatus
                motionStatus = MotionService.authorizationStatus
            }
        }
    }

    private var locationGranted: Bool {
        locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways
    }

    private var locationDetail: String {
        switch locationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return "On"
        case .denied, .restricted: return "Off"
        default: return "Asked on first run"
        }
    }

    private var motionDetail: String {
        switch motionStatus {
        case .authorized: return "On"
        case .denied, .restricted: return "Off"
        default: return "Asked on first run"
        }
    }

    private func permissionRow(_ title: String, granted: Bool, detail: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(detail)
                .foregroundStyle(granted ? Theme.accent : Theme.textSecondary)
        }
        .listRowBackground(Theme.surface)
    }

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
