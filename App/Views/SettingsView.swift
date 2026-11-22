import CoreLocation
import CoreMotion
import PaqoCore
import PaqoSensors
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(RunLibrary.self) private var library
    @AppStorage(SettingsKey.unit) private var unit: DistanceUnit = .localeDefault
    @AppStorage(SettingsKey.saveToHealth) private var saveToHealth = true
    @AppStorage(SettingsKey.recordSensorLogs) private var recordSensorLogs = true
    @Environment(\.openURL) private var openURL
    @State private var locationStatus = CLLocationManager().authorizationStatus
    @State private var motionStatus = MotionService.authorizationStatus

    /// One file picker serves both buttons: SwiftUI can drop a second
    /// `.fileImporter` in the same view.
    private enum PickerPurpose { case backupFolder, importRuns }
    @State private var pickerPurpose = PickerPurpose.importRuns
    @State private var showingPicker = false
    @State private var exporting = false
    @State private var sharedFile: SharedFile?
    @State private var message: String?
    @State private var logBytes: Int64 = 0
    @State private var reprocessIDs: [UUID] = []
    @State private var showingReprocess = false
    @State private var confirmDeleteLogs = false

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

                backupSection
                sensorLogSection

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
            .onAppear(perform: refresh)
            .fileImporter(
                isPresented: $showingPicker,
                allowedContentTypes: pickerPurpose == .backupFolder ? [.folder] : [.folder, .zip, .json],
                allowsMultipleSelection: pickerPurpose == .importRuns
            ) { result in
                guard case .success(let urls) = result, !urls.isEmpty else { return }
                switch pickerPurpose {
                case .backupFolder:
                    library.backup.chooseFolder(urls[0], library: library)
                case .importRuns:
                    Task { message = await library.backup.importRuns(from: urls, library: library) }
                }
            }
            .sheet(item: $sharedFile) { file in
                ShareSheet(items: [file.url])
            }
            .sheet(isPresented: $showingReprocess, onDismiss: refresh) {
                ReprocessSheet(ids: reprocessIDs)
            }
            .alert("Backup", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    // MARK: - Backup

    private var backupSection: some View {
        Section {
            Button {
                pickerPurpose = .backupFolder
                showingPicker = true
            } label: {
                HStack {
                    Text("Auto-backup folder")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(library.backup.folderName ?? "Off")
                        .foregroundStyle(library.backup.folderName == nil ? Theme.textSecondary : Theme.accent)
                        .lineLimit(1)
                }
            }
            .listRowBackground(Theme.surface)

            if library.backup.folderName != nil {
                HStack {
                    Text("Last backed up")
                    Spacer()
                    if library.backup.isWorking {
                        ProgressView()
                    } else {
                        Text(library.backup.lastBackup.map { $0.formatted(.relative(presentation: .named)) } ?? "Not yet")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .listRowBackground(Theme.surface)

                Button("Stop auto-backup", role: .destructive) {
                    library.backup.forgetFolder()
                }
                .listRowBackground(Theme.surface)
            }

            if let problem = library.backup.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .listRowBackground(Theme.surface)
            }

            Button {
                exportAll()
            } label: {
                HStack {
                    Text("Export all runs")
                    Spacer()
                    if exporting { ProgressView() }
                }
            }
            .disabled(exporting || library.summaries.isEmpty)
            .listRowBackground(Theme.surface)

            Button("Import runs") {
                pickerPurpose = .importRuns
                showingPicker = true
            }
            .listRowBackground(Theme.surface)
        } header: {
            Text("Backup")
        } footer: {
            Text("With auto-backup on, every run you finish, rename or delete is written to that folder: runs.csv and sprints.csv for spreadsheets, plus a JSON and GPX file per run. Pick a folder in iCloud Drive or OneDrive to see it on your computer. Deleted runs are moved to a \"deleted\" folder, never erased.")
        }
    }

    private func exportAll() {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                sharedFile = SharedFile(url: try await library.backup.exportAll(library: library))
            } catch {
                message = "Couldn't create the backup: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Sensor logs

    private var sensorLogSection: some View {
        Section {
            Toggle("Save sensor logs", isOn: $recordSensorLogs)
                .listRowBackground(Theme.surface)
            HStack {
                Text("Storage used")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: logBytes, countStyle: .file))
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)

            if !reprocessIDs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(reprocessIDs.count) run\(reprocessIDs.count == 1 ? " was" : "s were") recorded with older settings.")
                        .font(.subheadline)
                    Button("Re-process all") { showingReprocess = true }
                        .fontWeight(.semibold)
                }
                .listRowBackground(Theme.surface)
            }

            Button("Delete all logs", role: .destructive) {
                confirmDeleteLogs = true
            }
            .disabled(logBytes == 0)
            .listRowBackground(Theme.surface)
            .confirmationDialog("Delete every sensor log?", isPresented: $confirmDeleteLogs, titleVisibility: .visible) {
                Button("Delete all logs", role: .destructive) {
                    library.logs?.deleteAll()
                    refresh()
                }
            } message: {
                Text("Your runs stay. Only the raw sensor data is removed, so those runs can no longer be re-processed.")
            }
        } header: {
            Text("Sensor logs")
        } footer: {
            Text("Raw GPS, motion and accelerometer data for your last \(RunLibrary.sensorLogLimit) runs, used to fine-tune sprint detection. Share one from a run's ⋯ menu.")
        }
    }

    private func refresh() {
        locationStatus = CLLocationManager().authorizationStatus
        motionStatus = MotionService.authorizationStatus
        logBytes = library.logs?.totalBytes() ?? 0
        reprocessIDs = library.reprocessCandidates()
    }

    // MARK: - Permissions

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
