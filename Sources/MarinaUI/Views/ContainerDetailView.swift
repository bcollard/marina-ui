import SwiftUI
import AppKit

/// Detail for one container running in the guest VM that marina doesn't manage.
/// Everything shown comes from the single `docker ps` round-trip that built the
/// list; only the log tail costs an extra call, and only on demand.
struct ContainerDetailView: View {
    @Bindable var model: AppModel
    let container: DockerContainer

    @State private var logLines = 200
    @State private var showLogViewer = false

    /// Published ports are reachable from macOS at the VM's lima0 address.
    /// Lima additionally mirrors them onto 127.0.0.1, but marina's
    /// `network.disablePortMirroring` turns that off (it collides with other
    /// Lima VMs), so lima0 is the one address that works either way.
    private var hostAddress: String? { model.guestLima0IP }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                if container.compose != nil { composeCard }
                configCard
                if !container.ports.isEmpty { portsCard }
                if !container.labels.isEmpty { labelsCard }
                if !container.mountDetails.isEmpty || !container.mounts.isEmpty { mountsCard }
                logsCard
                if let rec = model.latestLog(for: .container(container.id)) {
                    LogConsoleView(title: "Last action", text: rec.text, maxHeight: 160)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: container.id) {
            if model.containerLogs[container.id] == nil {
                await model.loadContainerLogs(container, lines: logLines)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(container.name).font(.largeTitle.bold())
                    stateBadge
                }
                HStack(spacing: 8) {
                    Text(container.image)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("·").foregroundStyle(.tertiary)
                    Text(container.shortID)
                        .font(.callout.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .help(container.id)
                }
                if let compose = container.compose {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.down.right.fill")
                            .font(.caption)
                            .foregroundStyle(.teal)
                        Text(compose.serviceLabel.map { "\($0) in " } ?? "")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        + Text(compose.project)
                            .font(.callout.weight(.medium))
                            .foregroundColor(.teal)
                    }
                    .help("This container is part of a docker compose stack")
                }
            }
            Spacer()
            actionButtons
        }
    }

    private var stateBadge: some View {
        let tint: Color = {
            switch container.state {
            case "running": return .green
            case "paused", "restarting", "created": return .orange
            default: return .secondary
            }
        }()
        return Text(container.state.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
            .help(container.status)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if model.inFlightAction != nil {
                ProgressView().controlSize(.small)
            }
            if container.isRunning {
                Button {
                    Task { await model.performContainerAction(.restart, on: container) }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                Button(role: .destructive) {
                    Task { await model.performContainerAction(.stop, on: container) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .controlSize(.small)
            } else {
                Button {
                    Task { await model.performContainerAction(.start, on: container) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .disabled(model.inFlightAction != nil)
    }

    // MARK: - Cards

    /// Everything compose stamped onto the container. These come from their own
    /// `{{.Label "…"}}` columns, not the comma-joined `{{.Labels}}` blob — the
    /// config-file list would be mangled by that.
    @ViewBuilder
    private var composeCard: some View {
        if let compose = container.compose {
            GroupBox("Compose stack") {
                VStack(alignment: .leading, spacing: 6) {
                    row("Project", compose.project, mono: true,
                        help: "com.docker.compose.project — the stack name: the launch directory unless overridden with -p or COMPOSE_PROJECT_NAME.")
                    row("Service", compose.service ?? "—", mono: compose.service != nil)
                    if let n = compose.containerNumber {
                        row("Replica", "#\(n)",
                            help: "com.docker.compose.container-number — this container's index within the service.")
                    }
                    if compose.isOneOff {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Kind")
                                .frame(width: 140, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Label("one-off (docker compose run)", systemImage: "bolt.horizontal.circle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                    if let dir = compose.workingDir {
                        row("Working dir", dir, mono: true)
                    }
                    if !compose.configFiles.isEmpty {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Compose file\(compose.configFiles.count == 1 ? "" : "s")")
                                .frame(width: 140, alignment: .leading)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(compose.configFiles, id: \.self) { file in
                                    Text(file)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                    }
                    Text("Stopping this container does not stop the rest of the stack — use the Start/Stop buttons next to the stack's name in the sidebar or overview for that.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .padding(8)
            }
        }
    }

    private var configCard: some View {
        GroupBox("Container") {
            VStack(alignment: .leading, spacing: 6) {
                row("Status", container.status)
                row("Command", container.command, mono: true)
                row("Networks", container.networks.isEmpty ? "—" : container.networks.joined(separator: ", "),
                    help: "Containers on the \"kind\" network are resolvable by name from every kind node.")
                if let created = container.createdAt {
                    row("Created", created.formatted(date: .abbreviated, time: .shortened)
                        + "  (\(RelativeAge.format(since: created)) ago)")
                }
                row("Container ID", container.id, mono: true)
            }
            .padding(8)
        }
    }

    private var portsCard: some View {
        GroupBox("Ports") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(container.ports) { port in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: port.isPublished ? "arrow.right.circle.fill" : "circle.dashed")
                            .font(.caption)
                            .foregroundStyle(port.isPublished ? Color.green : Color.secondary)
                        Text(port.display)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        if let url = url(for: port) {
                            Link(destination: url) {
                                Label(url.absoluteString, systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        } else if !port.isPublished {
                            Text("exposed only — not published to the VM")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                if hostAddress == nil, container.ports.contains(where: \.isPublished) {
                    Text("The VM's lima0 address is unknown, so published ports can't be linked from here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            .padding(8)
        }
    }

    /// A published TCP port gets an http:// link against the VM's lima0 IP.
    /// We don't probe it — the container may well speak something other than
    /// HTTP — so the link is an affordance, not a claim of reachability.
    private func url(for port: DockerContainer.PortMapping) -> URL? {
        guard port.proto.lowercased() == "tcp",
              let hostPort = port.hostPort,
              let host = hostAddress
        else { return nil }
        return URL(string: "http://\(host):\(hostPort)")
    }

    private var labelsCard: some View {
        GroupBox("Labels") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(container.labels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(key)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(value.isEmpty ? "—" : value)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Mounts, with each bind judged against the directories the VM actually
    /// shares from the Mac.
    ///
    /// This is the one thing the app can tell you that `docker inspect` cannot:
    /// docker resolves a bind source *inside the guest*, so binding a host path
    /// marina doesn't share doesn't fail — dockerd creates it empty in the VM
    /// and the container quietly sees nothing. That is the failure `vm.mounts`
    /// exists to prevent, and it is invisible from inside the container.
    private var mountsCard: some View {
        GroupBox("Mounts") {
            VStack(alignment: .leading, spacing: 8) {
                if container.mountDetails.isEmpty {
                    // Pre-inspect fallback: the flat ps column, untyped.
                    ForEach(container.mounts, id: \.self) { mount in
                        Text(mount)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    ForEach(container.mountDetails) { mount in
                        mountRow(mount)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func mountRow(_ mount: DockerContainer.MountDetail) -> some View {
        let backing = model.backing(for: mount)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: mount.isBind ? "externaldrive.connected.to.line.below" : "internaldrive")
                    .font(.caption)
                    .foregroundStyle(tint(for: backing))
                Text(mount.destination)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Text(mount.rw ? "rw" : "ro")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("←")
                    .foregroundStyle(.tertiary)
                Text(mount.name ?? mount.source)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.leading, 18)
            backingNote(backing)
                .padding(.leading, 18)
        }
    }

    @ViewBuilder
    private func backingNote(_ backing: AppModel.MountBacking) -> some View {
        switch backing {
        case .hostShare(let share):
            Label(
                "on your Mac\(share.writable ? "" : " (share is read-only)")",
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(share.writable ? Color.green : Color.orange)
            .help("Backed by the VM share \(share.hostPath)")
        case .guestOnly:
            Label(
                "not shared from your Mac — this path exists only inside the VM",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .help("Docker resolves a bind source inside the guest. Add the directory to vm.mounts in your marina config and run `marina up` to share it.")
        case .notApplicable, .unknown:
            EmptyView()
        }
    }

    private func tint(for backing: AppModel.MountBacking) -> Color {
        switch backing {
        case .hostShare(let share): return share.writable ? .green : .orange
        case .guestOnly: return .orange
        case .notApplicable, .unknown: return .secondary
        }
    }

    private var logsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Logs").font(.headline)
                Picker("", selection: $logLines) {
                    Text("50").tag(50)
                    Text("200").tag(200)
                    Text("1000").tag(1000)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .onChange(of: logLines) { _, lines in
                    Task { await model.loadContainerLogs(container, lines: lines) }
                }
                Button {
                    Task { await model.loadContainerLogs(container, lines: logLines) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .help("Re-read the last \(logLines) lines")
                Spacer()
                Button {
                    showLogViewer = true
                } label: {
                    Label("Open log viewer", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .controlSize(.small)
                .help("Search, follow, timestamps, copy and save")
                .disabled(model.docker == nil)
            }
            .sheet(isPresented: $showLogViewer) {
                PodLogsView(source: .docker(id: container.id, name: container.name), docker: model.docker)
            }
            LogConsoleView(
                title: "docker logs --tail \(logLines) \(container.shortID)",
                text: model.containerLogs[container.id] ?? "Reading…",
                maxHeight: 320
            )
        }
    }

    private func row(_ k: String, _ v: String, mono: Bool = false, help: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 4) {
                Text(k).foregroundStyle(.secondary)
                if let help {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help(help)
                }
            }
            .frame(width: 140, alignment: .leading)
            Text(v)
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}
