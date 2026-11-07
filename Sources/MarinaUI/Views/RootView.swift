import SwiftUI

struct RootView: View {
    let model: AppModel
    @Environment(AppSettings.self) private var settings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            VStack(spacing: 0) {
                detailView
                if settings.showConsoleLog {
                    Divider()
                    ConsoleLogView(model: model)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.selection = nil
                } label: {
                    Label("Home", systemImage: "house")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .disabled(model.selection == nil)
                .help("Return to the overview (VM home)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.inFlightAction != nil)
                .help("Refresh VM, clusters, and mirrors (⌘R)")
            }
        }
        .task {
            await model.bootstrap()
        }
        .onChange(of: model.selection) { _, _ in
            Task { await model.refreshSelection() }
        }
        // Start or stop VM SSH polling when the user toggles VM stats visibility.
        .onChange(of: settings.showVMStats) { _, _ in
            model.startVMPollingIfRunning()
        }
        // The container list is only fetched while its preference is on, so
        // turning it on has to seed the list rather than wait for the next poll.
        .onChange(of: settings.showContainers) { _, on in
            if on {
                Task { await model.refreshContainers() }
            } else {
                if case .container = model.selection { model.selection = nil }
                model.containers = []
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch model.selection {
        case .cluster(let name):
            if let creation = model.creation, creation.name == name,
               creation.running || !model.clusters.contains(where: { $0.name == name }) {
                ClusterCreatingView(model: model, creation: creation)
            } else if let cluster = model.clusters.first(where: { $0.name == name }) {
                ClusterDetailView(model: model, cluster: cluster)
            } else {
                OverviewDetailView(model: model)
            }
        case .mirror(let name):
            if let mirror = model.mirrors.first(where: { $0.name == name }) {
                MirrorDetailView(model: model, mirror: mirror)
            } else {
                OverviewDetailView(model: model)
            }
        case .container(let id):
            if let container = model.containers.first(where: { $0.id == id }) {
                ContainerDetailView(model: model, container: container)
            } else {
                OverviewDetailView(model: model)
            }
        case .fleet(let name):
            if model.clusterGroups.contains(where: { $0.fleet == name }) {
                FleetDetailView(model: model, fleet: name)
            } else {
                OverviewDetailView(model: model)
            }
        case .none:
            OverviewDetailView(model: model)
        }
    }
}
