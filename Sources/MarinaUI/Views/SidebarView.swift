import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings
    @State private var showNewClusterSheet = false
    @State private var showNewFleetSheet = false
    @State private var newClusterName = ""
    @State private var mirrorsExpanded = true
    @State private var containersExpanded = true
    @State private var groupPendingRemoval: ContainerGroup?
    @State private var fleetPendingDeletion: ClusterGroup?

    var body: some View {
        List(selection: $model.selection) {
            Section {
                VMCard(model: model)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
            }

            Section {
                if model.clusters.isEmpty && model.provisioningClusterName == nil {
                    Text(
                        model.vm?.isRunning == true
                        ? "No clusters yet."
                        : "Start the VM to view clusters."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(model.clusterGroups) { group in
                        if !group.isUngrouped {
                            FleetGroupHeader(model: model, group: group) {
                                fleetPendingDeletion = group
                            }
                            .tag(SidebarSelection.fleet(name: group.fleet ?? ""))
                        }
                        ForEach(group.clusters) { c in
                            ClusterRow(
                                cluster: c,
                                createdAt: model.clusterCreatedAt[c.name],
                                isCurrentContext: model.currentKubeContext == c.name,
                                indented: !group.isUngrouped
                            )
                            .tag(SidebarSelection.cluster(name: c.name))
                            .contextMenu {
                                if let fleet = group.fleet {
                                    Button("Delete Fleet \"\(fleet)\"…", role: .destructive) {
                                        fleetPendingDeletion = group
                                    }
                                    .disabled(model.inFlightAction != nil)
                                }
                            }
                        }
                    }
                    if let name = model.provisioningClusterName {
                        ProvisioningRow(name: name, failed: model.creation?.failed == true)
                            .tag(SidebarSelection.cluster(name: name))
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    ZoneIcon(zone: .cluster, size: 16)
                    Text("Fleets & Clusters")
                        .font(.headline)
                        .textCase(nil)
                    Menu {
                        Button("New cluster…") {
                            newClusterName = ""
                            showNewClusterSheet = true
                        }
                        Button("New fleet…") { showNewFleetSheet = true }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.tint)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(model.vm?.isRunning != true || model.inFlightAction != nil)
                    .help("Create a cluster or a fleet")
                    if model.clustersLoading {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                }
                .padding(.bottom, 6)
            }

            if settings.showMirrors {
                Section(isExpanded: $mirrorsExpanded) {
                    if model.mirrors.isEmpty {
                        Text("No mirrors configured.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.mirrors, id: \.name) { m in
                            MirrorRow(mirror: m)
                                .tag(SidebarSelection.mirror(name: m.name))
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        ZoneIcon(zone: .mirror, size: 16)
                        Text("Registry mirrors")
                            .font(.headline)
                            .textCase(nil)
                    }
                    .padding(.bottom, 6)
                }
            }

            if settings.showContainers {
                Section(isExpanded: $containersExpanded) {
                    if model.vm?.isRunning != true {
                        Text("Start the VM to view containers.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if let error = model.containersError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if model.unmanagedContainers.isEmpty {
                        Text("No containers besides marina's own.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.containerGroups) { group in
                            // Only compose stacks get a heading; standalone
                            // containers would just be a header over a list of
                            // unrelated things.
                            if !group.isStandalone {
                                ComposeGroupHeader(model: model, group: group) {
                                    groupPendingRemoval = group
                                }
                            }
                            ForEach(group.containers) { c in
                                ContainerRow(container: c, indented: !group.isStandalone)
                                    .tag(SidebarSelection.container(id: c.id))
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        ZoneIcon(zone: .container, size: 16)
                        Text("Docker containers")
                            .font(.headline)
                            .textCase(nil)
                        if model.containersLoading {
                            ProgressView().controlSize(.mini)
                        }
                        Spacer()
                    }
                    .padding(.bottom, 6)
                    .help("Containers in the VM's Docker, other than marina's own kind nodes, registry mirrors and local DNS server.")
                }
            }

            // Footer: the active kube context, plus a way into the settings
            // window (versions and guest OS details live in its About tab).
            Section {
                VStack(alignment: .leading, spacing: 7) {
                    footerRow(
                        icon: "cube",
                        text: model.currentKubeContext ?? "no kube context",
                        help: "kubectl current-context",
                        style: model.currentKubeContext == nil
                            ? AnyShapeStyle(.tertiary)
                            : AnyShapeStyle(.primary)
                    )

                    Button {
                        openSettings()
                    } label: {
                        footerRow(
                            icon: "gearshape",
                            text: "Settings & About",
                            help: "Preferences, refresh intervals, and versions (⌘,)",
                            style: AnyShapeStyle(.secondary)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .sheet(isPresented: $showNewClusterSheet) {
            NewClusterSheet(model: model, isPresented: $showNewClusterSheet)
        }
        .sheet(isPresented: $showNewFleetSheet) {
            NewFleetSheet(model: model, isPresented: $showNewFleetSheet)
        }
        .confirmationDialog(
            groupPendingRemoval.map { "Remove stack \"\($0.title)\"?" } ?? "",
            isPresented: Binding(
                get: { groupPendingRemoval != nil },
                set: { if !$0 { groupPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let group = groupPendingRemoval {
                Button("Remove \(group.containers.count) container\(group.containers.count == 1 ? "" : "s")", role: .destructive) {
                    Task { await model.performStackRemoval(group) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This force-removes every container in the stack, running or not. This cannot be undone.")
        }
        .fleetDeletionDialog(model: model, pending: $fleetPendingDeletion)
    }

    /// One line in the sidebar footer. The icon sits in a fixed-width slot so
    /// every label starts on the same x regardless of glyph width.
    private func footerRow(
        icon: String,
        text: String,
        help: String,
        style: AnyShapeStyle = AnyShapeStyle(.tertiary)
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .frame(width: 13, alignment: .center)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
            // No .textSelection here: selectable Text draws in the label color
            // and ignores .foregroundStyle, which flattens the whole footer to
            // white. Copyability isn't worth losing the hierarchy.
        }
        .font(.caption2)
        .foregroundStyle(style)
        .help(help)
    }
}

private struct ClusterRow: View {
    let cluster: KindCluster
    let createdAt: Date?
    var isCurrentContext: Bool = false
    /// Inset under a fleet heading.
    var indented: Bool = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(cluster.name)
                    if isCurrentContext {
                        Text("current")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.18)))
                            .help("kubectl current-context")
                    }
                }
                HStack(spacing: 6) {
                    if let createdAt {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(RelativeAge.format(since: createdAt, now: context.date))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("—")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } icon: {
            Image(systemName: "circle.grid.3x3.fill")
                .foregroundStyle(.blue)
        }
        .padding(.leading, indented ? 10 : 0)
    }
}

/// Heading for one fleet inside the Clusters section. Tagged
/// `.fleet(name:)`, so selecting it opens the fleet view.
private struct FleetGroupHeader: View {
    @Bindable var model: AppModel
    let group: ClusterGroup
    let onRequestDeletion: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: UIZone.fleet.symbol)
                .font(.caption2)
                .foregroundStyle(UIZone.fleet.color)
            ZoneTag(zone: .fleet, text: "Fleet")
            Text(group.fleet ?? "")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(group.clusters.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if model.inFlightAction != nil {
                ProgressView().controlSize(.mini)
            } else {
                Button(role: .destructive) {
                    onRequestDeletion()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Delete every cluster in this fleet — cannot be undone")
            }
        }
        .font(.caption2)
        .padding(.top, 4)
        .help("Fleet \"\(group.fleet ?? "")\" — click for members, options, addons and manifest")
    }
}

private struct ProvisioningRow: View {
    let name: String
    let failed: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(failed ? "failed" : "creating…")
                    .font(.caption2)
                    .foregroundStyle(failed ? .red : .secondary)
            }
        } icon: {
            if failed {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
    }
}

private struct MirrorRow: View {
    let mirror: MarinaConfig.Registries.Mirror

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(mirror.name)
                Text(mirror.remoteURL)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .truncationMode(.tail)
            }
        } icon: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(UIZone.mirror.color)
        }
    }
}

/// Heading for one `docker compose` project inside the Containers section.
/// Not tagged, so it never becomes a selectable row.
private struct ComposeGroupHeader: View {
    @Bindable var model: AppModel
    let group: ContainerGroup
    let onRequestRemoval: () -> Void

    private var allRunning: Bool { group.runningCount == group.containers.count }
    private var allStopped: Bool { group.runningCount == 0 }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "square.stack.3d.down.right.fill")
                .font(.caption2)
                .foregroundStyle(.teal)
            Text(group.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(group.runningCount)/\(group.containers.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if model.inFlightAction != nil {
                ProgressView().controlSize(.mini)
            } else {
                Button {
                    Task { await model.performStackAction(.stop, on: group) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.plain)
                .disabled(allStopped)
                .help("Stop every container in this stack")
                Button {
                    Task { await model.performStackAction(.start, on: group) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.plain)
                .disabled(allRunning)
                .help("Start every container in this stack")
                Button(role: .destructive) {
                    onRequestRemoval()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Remove every container in this stack — cannot be undone")
            }
        }
        .font(.caption2)
        .padding(.top, 4)
        .help(
            "docker compose project \"\(group.title)\""
            + (group.workingDir.map { "\n\($0)" } ?? "")
        )
    }
}

private struct ContainerRow: View {
    let container: DockerContainer
    /// Inset under a compose project heading.
    var indented: Bool = false

    /// Inside a stack the service name is what identifies the container; the
    /// full name is just `<project>-<service>-<n>` repeated on every row.
    private var title: String {
        container.compose?.serviceLabel ?? container.name
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if container.compose?.isOneOff == true {
                        Text("one-off")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                            .help("Started by `docker compose run`, not part of the stack's services")
                    }
                }
                Text(container.image)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(container.isRunning ? .teal : .gray)
        }
        .padding(.leading, indented ? 10 : 0)
        .help("\(container.name)\n\(container.status) — \(container.shortID)")
    }
}

private struct VMCard: View {
    @Bindable var model: AppModel
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.selection = nil
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        if let img = AppAssets.logo {
                            Image(nsImage: img)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.vm?.name ?? "marina")
                                .font(.headline)
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(model.vm?.isRunning == true ? .green : .gray)
                                    .frame(width: 7, height: 7)
                                Text(statusText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "house")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if let vm = model.vm {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            metaRow("CPUs", vm.lima?.cpus.map(String.init) ?? "—")
                            metaRow("Memory", vm.lima?.memory ?? "—")
                            if settings.showVMStats, let disk = model.guestStats?.rootDisk {
                                diskRow("Disk", disk)
                            } else {
                                metaRow("Disk", vm.lima?.disk ?? "—")
                            }
                            if settings.showVMStats, let images = model.guestStats?.imageDisk {
                                diskRow("Images", images)
                            }
                            if settings.showVMStats, let loadAvg = model.guestStats?.loadAvg {
                                let parts = Array(loadAvg.split(separator: " ").prefix(3))
                                HStack {
                                    Text("Load")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                    Spacer()
                                    loadText(parts)
                                        .font(.caption.monospacedDigit())
                                        .textSelection(.enabled)
                                }
                                .help(loadHelp(parts))
                            }
                            if settings.showVMStats,
                               let total = model.guestStats?.memTotalKB,
                               let avail = model.guestStats?.memAvailableKB
                            {
                                let usedGiB = Double(total - avail) / 1024 / 1024
                                let totalGiB = Double(total) / 1024 / 1024
                                let ratio = total > 0 ? Double(total - avail) / Double(total) : 0
                                HStack {
                                    Text("Used")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                    Spacer()
                                    // Only the current usage is tinted; the total
                                    // allocation stays in the default color.
                                    (
                                        Text(String(format: "%.1f", usedGiB))
                                            .foregroundColor(usageColor(ratio, warn: 0.7, crit: 0.9))
                                        // Pin the total to secondary so it stays a constant
                                        // dark grey instead of following the window's
                                        // key-state (active=white / inactive=grey) dimming.
                                        + Text(String(format: " / %.1f GiB", totalGiB))
                                            .foregroundColor(.secondary)
                                    )
                                    .font(.caption.monospacedDigit())
                                    .textSelection(.enabled)
                                }
                            }
                            if let ip = model.guestLima0IP {
                                metaRow("IP address (lima0)", ip)
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // No card-wide .help here: it would override the per-row tooltips
            // (e.g. the Load breakdown). The home affordance is covered by the
            // toolbar Home button and clicking the card.

            HStack(spacing: 6) {
                if let label = model.inFlightAction {
                    ProgressView().controlSize(.mini)
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                } else {
                    if model.vm?.isRunning == true {
                        Button(role: .destructive) {
                            Task { await model.stopVM() }
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .controlSize(.small)
                    } else {
                        Button {
                            Task { await model.startVM() }
                        } label: {
                            Label("Start", systemImage: "play.fill")
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                }
            }
            .disabled(model.inFlightAction != nil)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var statusText: String {
        switch model.vm?.runtime {
        case .running: return "Running"
        case .stopped, .none: return "Stopped"
        case .unknown: return "Unknown"
        }
    }

    private func metaRow(_ k: String, _ v: String, valueColor: Color? = nil) -> some View {
        HStack {
            Text(k)
                .foregroundStyle(.secondary)
                .font(.caption)
            Spacer()
            Text(v)
                .font(.caption.monospacedDigit())
                .foregroundStyle(valueColor ?? .primary)
                .textSelection(.enabled)
        }
    }

    /// Traffic-light color for a 0…1 usage ratio.
    private func usageColor(_ ratio: Double, warn: Double, crit: Double) -> Color {
        if ratio >= crit { return .red }
        if ratio >= warn { return .orange }
        return .green
    }

    /// A disk usage row in the same "used / total" style as the Memory row,
    /// colored by fraction full. Thresholds sit higher than memory's (80/95%
    /// vs 70/90%) — disks routinely run hotter than RAM without it meaning
    /// anything, so the warning should reserve itself for genuinely tight space.
    private func diskRow(_ label: String, _ disk: GuestSSH.DiskUsage) -> some View {
        let usedGiB = Double(disk.usedKB) / 1024 / 1024
        let totalGiB = Double(disk.totalKB) / 1024 / 1024
        let ratio = disk.totalKB > 0 ? Double(disk.usedKB) / Double(disk.totalKB) : 0
        return HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.caption)
            Spacer()
            (
                Text(String(format: "%.1f", usedGiB))
                    .foregroundColor(usageColor(ratio, warn: 0.8, crit: 0.95))
                + Text(String(format: " / %.1f GiB", totalGiB))
                    .foregroundColor(.secondary)
            )
            .font(.caption.monospacedDigit())
            .textSelection(.enabled)
        }
        .help("\(disk.device) — \(Int((ratio * 100).rounded()))% used")
    }

    /// Tooltip breaking the load average into its 1/5/15-minute components,
    /// with the per-core ratio for the 1-minute figure (which drives the color).
    private func loadHelp(_ parts: [Substring]) -> String {
        let labels = ["1 min", "5 min", "15 min"]
        var lines = zip(labels, parts).map { "\($0): \($1)" }
        if let first = parts.first, let load = Double(first),
           let cores = model.vm?.lima?.cpus, cores > 0 {
            lines.append("")
            lines.append(String(format: "%.0f%% of %d cores (1 min)", load / Double(cores) * 100, cores))
        }
        return "Load average\n" + lines.joined(separator: "\n")
    }

    /// Color one load figure by its own load-per-core ratio: green <70%,
    /// orange 70–90%, red ≥90%. Default color when cores are unknown.
    private func loadFieldColor(_ field: Substring) -> Color {
        guard let load = Double(field), let cores = model.vm?.lima?.cpus, cores > 0
        else { return .primary }
        return usageColor(load / Double(cores), warn: 0.7, crit: 0.9)
    }

    /// The 1/5/15-minute load figures as one Text, each colored independently.
    private func loadText(_ parts: [Substring]) -> Text {
        var result = Text("")
        for (i, field) in parts.enumerated() {
            if i > 0 { result = result + Text(" ") }
            result = result + Text(String(field)).foregroundColor(loadFieldColor(field))
        }
        return result
    }
}

