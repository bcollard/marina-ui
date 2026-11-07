import SwiftUI

/// One fleet: its members with their options, addons and status, and the
/// manifest as YAML. Reads `marina fleet describe -o json`, which resolves
/// members by the marina.run/fleet node label, like every other fleet command.
struct FleetDetailView: View {
    @Bindable var model: AppModel
    let fleet: String

    @State private var description: FleetDescription?
    @State private var error: String?
    @State private var loading = false
    @State private var showYAML = false

    /// Reload when membership changes (a cluster created or deleted elsewhere).
    private var reloadKey: String {
        let members = model.clusterGroups.first { $0.fleet == fleet }?.clusters.map(\.name) ?? []
        return fleet + "|" + members.joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    if let d = description {
                        membersCard(d)
                        manifestCard(d)
                    } else if loading {
                        ProgressView("Reading fleet…")
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: reloadKey) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            description = try await MarinaCLI.describeFleet(fleet)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ZoneIcon(zone: .fleet, size: 30)
                    ZoneTag(zone: .fleet, text: "Fleet")
                    Text(fleet).font(.largeTitle.bold())
                }
                if let d = description {
                    HStack(spacing: 12) {
                        pill("clusters", "\(d.members.count)")
                        pill("ready", "\(d.readyCount)/\(d.members.count)",
                             color: d.readyCount == d.members.count ? .green : .orange)
                        if let v = commonVersion(d) { pill("k8s", v) }
                        if let date = d.appliedDate {
                            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                                pill("applied", RelativeAge.format(since: date, now: ctx.date) + " ago")
                            }
                        }
                    }
                    .font(.callout)
                }
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Re-read the fleet")
            .disabled(loading)
        }
    }

    private func commonVersion(_ d: FleetDescription) -> String? {
        let versions = Set(d.members.map(\.k8sVersion).filter { !$0.isEmpty })
        return versions.count == 1 ? versions.first : (versions.isEmpty ? nil : "mixed")
    }

    // MARK: - Members

    private func membersCard(_ d: FleetDescription) -> some View {
        GroupBox("Members") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(d.members.enumerated()), id: \.element.id) { i, m in
                    if i > 0 { Divider().padding(.vertical, 8) }
                    memberRow(m)
                }
                if d.members.contains(where: { $0.options == nil }) {
                    Divider().padding(.vertical, 8)
                    Text("Clusters without recorded options were created before marina v0.3.10, or adopted with `marina fleet adopt`. dependsOn and registry selection are not recoverable for them; addons are detected live.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        }
    }

    private func memberRow(_ m: FleetDescription.Member) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(m.ready ? Color.green : (m.nodes == 0 ? Color.red : Color.orange))
                    .frame(width: 8, height: 8)
                Button {
                    model.selection = .cluster(name: m.name)
                } label: {
                    Text(m.name).font(.headline)
                }
                .buttonStyle(.link)
                .help("Open cluster \(m.name)")
                Text(m.nodes == 0 ? "unreachable" : (m.ready ? "Ready" : "NotReady"))
                    .font(.caption)
                    .foregroundStyle(m.ready ? Color.secondary : Color.orange)
                Spacer()
                Text("num \(m.num) · API :\(String(m.apiPort))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            grid(m)
        }
    }

    private func grid(_ m: FleetDescription.Member) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Kubernetes", "\(m.k8sVersion.isEmpty ? "—" : m.k8sVersion) · \(m.nodes) node\(m.nodes == 1 ? "" : "s")")
            if m.region != nil || m.zone != nil {
                row("Topology", [m.region, m.zone].compactMap { $0 }.joined(separator: " / "))
            }
            if let deps = m.options?.dependsOn, !deps.isEmpty {
                GridRow {
                    label("Depends on")
                    HStack(spacing: 4) {
                        ForEach(deps, id: \.self) { dep in
                            Button(dep) { model.selection = .cluster(name: dep) }
                                .buttonStyle(.link)
                                .font(.callout.monospaced())
                        }
                    }
                }
            }
            if let o = m.options {
                row("Registries", o.mirrorsSummary, mono: o.registries?.mirrors?.isEmpty == false)
            }
            GridRow {
                label("Addons")
                addons(m)
            }
            if !m.customLabels.isEmpty {
                GridRow {
                    label("Labels")
                    FlowChips(items: m.customLabels.map { "\($0.key)=\($0.value)" })
                }
            }
        }
    }

    @ViewBuilder
    private func addons(_ m: FleetDescription.Member) -> some View {
        let live = m.addons?.metricsServer
        let declared = m.options?.addons?.metricsServer?.enabled == true
        if let live, live.installed {
            chip("metrics-server \(live.version ?? "")",
                 systemImage: live.ready ? "checkmark.circle.fill" : "hourglass",
                 color: live.ready ? .green : .orange)
                .help(live.ready ? "Installed and ready" : "Installed, not ready yet")
        } else if declared {
            chip("metrics-server missing", systemImage: "exclamationmark.triangle.fill", color: .red)
                .help("The manifest enables metrics-server, but its Deployment is not in kube-system")
        } else {
            Text("none").font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Manifest

    private func manifestCard(_ d: FleetDescription) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle(isOn: $showYAML.animation()) {
                        Text("Show full YAML")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Spacer()
                }
                Text(d.manifestWasApplied
                     ? "The manifest as last applied (`marina fleet create -f`), kept in each member's kube-system/marina-fleet ConfigMap."
                     : "Rebuilt from live state, like `marina fleet export`: no member recorded the manifest it was created from.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showYAML, let yaml = d.manifest, !yaml.isEmpty {
                    YAMLBlockView(yaml: yaml, fileName: "\(fleet).yaml")
                }
            }
            .padding(6)
        } label: {
            Text("Manifest")
        }
    }

    // MARK: - Bits

    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            label(title)
            Text(value)
                .font(mono ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
        }
    }

    private func label(_ s: String) -> some View {
        // Fixed width: each member is its own Grid, so the column must not size to its content.
        Text(s).font(.caption).foregroundStyle(.secondary)
            .frame(width: 84, alignment: .trailing)
    }

    private func pill(_ title: String, _ value: String, color: Color = .secondary) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium).foregroundStyle(color == .secondary ? .primary : color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private func chip(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// Wrapping row of small monospaced chips.
struct FlowChips: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    .textSelection(.enabled)
            }
        }
    }
}
