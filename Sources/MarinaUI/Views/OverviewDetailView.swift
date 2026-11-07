import SwiftUI
import AppKit

/// Default screen — shows when no sidebar item is selected. Acts as a dashboard
/// listing clusters and registry mirrors, both clickable to drill into details.
struct OverviewDetailView: View {
    @Bindable var model: AppModel
    @Environment(AppSettings.self) private var settings
    @State private var showNewClusterSheet = false
    @State private var showDeleteAllConfirm = false
    @State private var groupPendingRemoval: ContainerGroup?
    @State private var fleetPendingDeletion: ClusterGroup?

    private var clustersHeaderTrailing: AnyView {
        AnyView(
            HStack(spacing: 8) {
                if model.clustersLoading {
                    ProgressView().controlSize(.mini)
                }
                if !model.clusters.isEmpty {
                    Button(role: .destructive) {
                        showDeleteAllConfirm = true
                    } label: {
                        Label("Delete all", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(model.inFlightAction != nil)
                    .help("Delete every kind cluster")
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                clustersSection
                if settings.showMirrors {
                    mirrorsSection
                }
                if settings.showContainers {
                    containersSection
                }
                if settings.showVMStats, model.vm?.isRunning == true {
                    VMChartsView(model: model)
                }
                if let mounts = model.hostMounts, !mounts.shares.isEmpty {
                    hostMountsSection(mounts)
                }
                if let rec = model.logRecords.last(where: { $0.scope.showsOnOverview }) {
                    LogConsoleView(title: "Last action", text: rec.text, maxHeight: 200)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showNewClusterSheet) {
            NewClusterSheet(model: model, isPresented: $showNewClusterSheet)
        }
        .confirmationDialog(
            "Delete all \(model.clusters.count) clusters?",
            isPresented: $showDeleteAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete all clusters", role: .destructive) {
                Task { await model.deleteAllClusters() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This tears down every kind cluster in the VM. This cannot be undone.")
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

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            if let img = AppAssets.logo {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(radius: 4)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("marina").font(.largeTitle.bold())
                configRow
            }
            Spacer()
        }
    }

    private var configRow: some View {
        let url = InstanceDiscovery.configFile()
        return HStack(spacing: 8) {
            Text(prettyPath(url.path))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "pencil")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .help("Open \(url.lastPathComponent) in the default editor")
        }
    }

    /// Replace the user's home directory prefix with `~` for compact display.
    private func prettyPath(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if p.hasPrefix(home) {
            return "~" + p.dropFirst(home.count)
        }
        return p
    }

    // MARK: - Clusters

    private var clustersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                title: "Fleets & Clusters",
                count: model.clusters.count,
                trailing: clustersHeaderTrailing,
                zone: .cluster
            )
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.clusterGroups) { group in
                    if !group.isUngrouped {
                        VStack(alignment: .leading, spacing: 8) {
                            fleetGroupHeader(group)
                            clusterGrid(group.clusters)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(UIZone.fleet.color.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(UIZone.fleet.color.opacity(0.22), lineWidth: 1)
                        )
                    }
                }
                // Ungrouped clusters, plus the provisioning and "new" cards,
                // share the last grid so the create affordance stays at the end.
                clusterGrid(
                    model.clusterGroups.first(where: \.isUngrouped)?.clusters ?? [],
                    trailingCards: true
                )
            }
        }
    }

    private func clusterGrid(
        _ clusters: [KindCluster],
        trailingCards: Bool = false
    ) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 260), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(clusters) { c in
                ClusterCard(cluster: c) {
                    model.selection = .cluster(name: c.name)
                }
            }
            if trailingCards {
                if let name = model.provisioningClusterName {
                    ProvisioningClusterCard(
                        name: name,
                        failed: model.creation?.failed == true
                    ) {
                        model.selection = .cluster(name: name)
                    }
                }
                NewClusterCard(
                    disabled: model.vm?.isRunning != true || model.inFlightAction != nil,
                    disabledReason: model.vm?.isRunning == true ? nil : "Start the VM first"
                ) {
                    showNewClusterSheet = true
                }
            }
        }
    }

    private func fleetGroupHeader(_ group: ClusterGroup) -> some View {
        HStack(spacing: 6) {
            ZoneIcon(zone: .fleet, size: 18)
            Text("Fleet")
                .font(.headline)
                .foregroundStyle(UIZone.fleet.color)
            Button {
                model.selection = .fleet(name: group.fleet ?? "")
            } label: {
                Text(group.fleet ?? "")
                    .font(.headline)
            }
            .buttonStyle(.link)
            .help("Open fleet \"\(group.fleet ?? "")\": members, options, addons and manifest")
            Text("\(group.clusters.count) cluster\(group.clusters.count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if model.inFlightAction != nil {
                ProgressView().controlSize(.small)
            } else {
                Button(role: .destructive) {
                    fleetPendingDeletion = group
                } label: {
                    Label("Delete fleet", systemImage: "trash")
                }
                .controlSize(.small)
                .help("Delete every cluster in this fleet — cannot be undone")
            }
        }
        .help("Fleet \"\(group.fleet ?? "")\" (marina.run/fleet)")
    }

    // MARK: - Mirrors

    private var mirrorsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Registry mirrors", count: model.mirrors.count, trailing: nil, zone: .mirror)
            if model.mirrors.isEmpty {
                emptyCard("No mirrors configured.")
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(model.mirrors, id: \.name) { m in
                        MirrorCard(mirror: m) {
                            model.selection = .mirror(name: m.name)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Containers

    private var containersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                title: "Docker containers",
                count: model.unmanagedContainers.count,
                trailing: AnyView(
                    HStack(spacing: 8) {
                        if model.containersLoading {
                            ProgressView().controlSize(.mini)
                        }
                        Button {
                            Task { await model.refreshContainers() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .help("Re-list the VM's containers")
                    }
                ),
                zone: .container
            )
            if model.vm?.isRunning != true {
                emptyCard("Start the VM to view containers.")
            } else if let error = model.containersError {
                emptyCard(error)
            } else if model.unmanagedContainers.isEmpty {
                emptyCard("No containers besides marina's own.")
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.containerGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            // Only compose stacks get a sub-heading; the
                            // standalone bucket is just the rest.
                            if !group.isStandalone {
                                composeGroupHeader(group)
                            }
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 260), spacing: 12)],
                                alignment: .leading,
                                spacing: 12
                            ) {
                                ForEach(group.containers) { c in
                                    ContainerCard(container: c) {
                                        model.selection = .container(id: c.id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func composeGroupHeader(_ group: ContainerGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.down.right.fill")
                .font(.caption)
                .foregroundStyle(.teal)
            Text(group.title)
                .font(.headline)
            Text("\(group.runningCount)/\(group.containers.count) up")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let dir = group.workingDir {
                Text(dir)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.inFlightAction != nil {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.performStackAction(.stop, on: group) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .controlSize(.small)
                .disabled(group.runningCount == 0)
                .help("Stop every container in this stack")
                Button {
                    Task { await model.performStackAction(.start, on: group) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .controlSize(.small)
                .disabled(group.runningCount == group.containers.count)
                .help("Start every container in this stack")
                Button(role: .destructive) {
                    groupPendingRemoval = group
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .help("Remove every container in this stack — cannot be undone")
            }
        }
        .help("docker compose project \"\(group.title)\"")
    }

    // MARK: - Host mounts

    /// What the VM can see of the Mac. Worth its own section because it is the
    /// precondition for `docker run -v <host path>` resolving to anything: a
    /// bind outside these directories doesn't fail, it silently gets an empty
    /// directory created inside the guest.
    private func hostMountsSection(_ mounts: MarinaStatus.Mounts) -> some View {
        let user = mounts.shares.filter { !$0.isMarinaInternal }
        // marina's own registry-cache share goes last and greyed: it is real
        // (a bind into it genuinely reaches the Mac) but it's plumbing, not
        // something the user configured.
        let ordered = user + mounts.shares.filter(\.isMarinaInternal)
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                title: "Volume mounts",
                count: user.count,
                trailing: mounts.pendingRestart ? AnyView(pendingRestartBadge) : nil,
                zone: .mounts
            )
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ordered) { share in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: share.isMarinaInternal ? "shippingbox" : "folder")
                            .font(.caption)
                            .foregroundStyle(share.isMarinaInternal ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                        Text(prettyPath(share.hostPath))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if share.guestPath != share.hostPath {
                            Text("→ \(share.guestPath)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        pill(share.writable ? "writable" : "read-only")
                        if share.isMarinaInternal {
                            Text("marina")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .opacity(share.isMarinaInternal ? 0.45 : 1)
                    .help(share.isMarinaInternal ? "Shared by marina itself, for the registry mirror cache" : "")
                    if share.id != ordered.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06))
            )
            Text("Only these directories resolve for a `docker run -v <host path>`. Anything else is created empty inside the VM — the container starts, and sees nothing.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pendingRestartBadge: AnyView {
        AnyView(
            Label("restart pending", systemImage: "exclamationmark.arrow.circlepath")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .help("vm.mounts in your marina config no longer matches what the VM has. Run `marina up` to apply it — it will offer to restart the VM.")
        )
    }

    // MARK: - Bits

    private func sectionHeader(title: String, count: Int, trailing: AnyView?, zone: UIZone? = nil) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if let zone { ZoneIcon(zone: zone, size: 22) }
            Text(title).font(.title3.bold())
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            if let trailing { trailing }
            Spacer()
        }
    }

    private func emptyCard(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.06))
            )
    }
}

// MARK: - Cards

private struct ClusterCard: View {
    let cluster: KindCluster
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "circle.grid.3x3.fill")
                        .foregroundStyle(.blue)
                    Text(cluster.name).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                HStack(spacing: 6) {
                    pill("num \(cluster.num)")
                    pill("api :\(cluster.apiPort)")
                }
                Text(cluster.kubeconfigPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(UIZone.cluster.color.opacity(hovering ? 0.16 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(hovering ? 0.25 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MirrorCard: View {
    let mirror: MarinaConfig.Registries.Mirror
    let action: () -> Void
    @State private var hovering = false

    private var remoteHost: String {
        URL(string: mirror.remoteURL)?.host ?? mirror.remoteURL
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.purple)
                    Text(mirror.name).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                HStack(spacing: 6) {
                    pill(":\(mirror.port)")
                    pill(remoteHost)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(UIZone.mirror.color.opacity(hovering ? 0.16 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(hovering ? 0.25 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ContainerCard: View {
    let container: DockerContainer
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: UIZone.container.symbol)
                        .foregroundStyle(container.isRunning ? UIZone.container.color : .gray)
                    // Within a stack the service is the identity; the full name
                    // is `<project>-<service>-<n>` on every card.
                    Text(container.compose?.serviceLabel ?? container.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                HStack(spacing: 6) {
                    pill(container.state)
                    if container.compose?.isOneOff == true {
                        pill("one-off")
                    }
                    ForEach(container.ports.filter(\.isPublished).prefix(2)) { port in
                        pill(":\(port.hostPort ?? 0)")
                    }
                }
                Text(container.image)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(UIZone.container.color.opacity(hovering ? 0.16 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(hovering ? 0.25 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(container.name)\n\(container.status)")
    }
}

private struct ProvisioningClusterCard: View {
    let name: String
    let failed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if failed {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(name).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                Text(failed ? "Creation failed — tap for log" : "Creating… tap to follow log")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(UIZone.cluster.color.opacity(hovering ? 0.16 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(hovering ? 0.25 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct NewClusterCard: View {
    let disabled: Bool
    let disabledReason: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(disabled ? Color.secondary : Color.accentColor)
                Text("New cluster")
                    .font(.headline)
                    .foregroundStyle(disabled ? Color.secondary : Color.primary)
                if let disabledReason {
                    Text(disabledReason)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(hovering && !disabled ? 0.10 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        Color.secondary.opacity(hovering && !disabled ? 0.45 : 0.25),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(disabled ? (disabledReason ?? "Create a new kind cluster") : "Create a new kind cluster")
    }
}

private func pill(_ text: String) -> some View {
    Text(text)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
}
