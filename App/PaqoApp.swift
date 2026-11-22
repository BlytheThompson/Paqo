import SwiftUI

@main
@MainActor
struct PaqoApp: App {
    @State private var library: RunLibrary
    @State private var controller: RunController

    init() {
        let library = RunLibrary()
        _library = State(initialValue: library)
        _controller = State(initialValue: RunController(library: library))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(controller)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    enum AppTab: Hashable {
        case run, history, records, settings
    }

    @Environment(RunController.self) private var controller
    @State private var tab: AppTab = .run

    var body: some View {
        TabView(selection: $tab) {
            StartView()
                .tabItem { Label("Run", systemImage: "figure.run") }
                .tag(AppTab.run)
            HistoryView()
                .tabItem { Label("History", systemImage: "list.bullet") }
                .tag(AppTab.history)
            RecordsView()
                .tabItem { Label("Records", systemImage: "trophy") }
                .tag(AppTab.records)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .fullScreenCover(isPresented: Binding(
            get: { controller.isLiveScreenPresented },
            set: { _ in }
        )) {
            LiveFlowView()
        }
    }
}

/// Countdown → live run → summary, all inside one full-screen cover.
struct LiveFlowView: View {
    @Environment(RunController.self) private var controller

    var body: some View {
        switch controller.phase {
        case .countdown(let n):
            CountdownView(number: n)
        case .finished:
            if let run = controller.finishedRun {
                NavigationStack {
                    RunSummaryView(run: run, justFinished: true) {
                        controller.dismissSummary()
                    }
                }
            }
        default:
            LiveRunView()
        }
    }
}
