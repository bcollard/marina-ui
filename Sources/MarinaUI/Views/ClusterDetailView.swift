import SwiftUI

struct ClusterDetailView: View {
    @Bindable var model: AppModel
    let cluster: KindCluster
    @State private var tab: Tab = .info
    @State private var showAddLabel = false
    @State private var newLabelKey = ""
    @State private var newLabelValue = ""
    @State private var labelError: String?
    @State private var confirmAttach = false
    @State private var confirmCAAttach = false

    enum Tab: Hashable { case info, services, metrics }

    private var detail: AppModel.ClusterDetail? {
        if model.clusterDetail?.cluster.name == cluster.name {
            return model.clusterDetail
        }
        return nil
    }

    /// Which action log this view surfaces: the Metrics tab shows metrics-server
    /// ops, the other tabs show the cluster's lifecycle actions.
    private var logScope: LogScope {
        tab == .metrics ? .metrics(cluster.name) : .cluster(cluster.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                Picker("", selection: $tab) {
                    Text("Info").tag(Tab.info)
                    Text("Services").tag(Tab.services)
                    Text("Metrics").tag(Tab.metrics)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360, alignment: .leading)
                .padding(.top, 10)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let err = detail?.error {
                        errorBanner(err)
                    }
                    switch tab {
                    case .info:
                        podsCard
                        nodesCard
                        if let zone = model.dnsZone(for: cluster.name) {
                            localDNSCard(zone: zone)
                        }
                        kubeconfigCard
                    case .services:
                        ServicesTabView(
                            model: model,
                            cluster: cluster,
                            services: detail?.services ?? [],
                            bridgeCIDR: model.config?.network?.kindBridgeCIDR
                        )
                    case .metrics:
                        metricsTabBody
                    }
                    if let rec = model.latestLog(for: logScope) {
                        LogConsoleView(
                            title: "Last action log",
                            text: rec.text,
                            maxHeight: 180
                        )
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: cluster.name) {
            await model.loadClusterDetail(for: cluster)
        }
    }

    @ViewBuilder
    private var metricsTabBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            metricsServerCard
            if detail?.metricsServerReady == true {
                MetricsChartsView(model: model, cluster: cluster)
            } else {
                Text("Install metrics-server above to enable live CPU and memory graphs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 8) {
                Text(cluster.name).font(.largeTitle.bold())
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    HStack(spacing: 12) {
                        if let fleet = nodeLabels?[Self.fleetLabelKey] {
                            fleetBadge(fleet)
                        }
                        if let v = detail?.serverVersion {
                            metaPill("k8s", v)
                        }
                        if let createdAt = model.clusterCreatedAt[cluster.name] {
                            metaPill("age", RelativeAge.format(since: createdAt, now: context.date))
                        }
                        if let region = nodeLabels?[Self.regionLabelKey] {
                            metaPill("region", region)
                        }
                        if let zone = nodeLabels?[Self.zoneLabelKey] {
                            metaPill("zone", zone)
                        }
                    }
                    .font(.callout)
                }
                labelsRow
            }
            Spacer()
            if detail?.loading == true {
                ProgressView().controlSize(.small)
            }
            if model.currentKubeContext == cluster.name {
                Label("Current context", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("kubectl current-context is \(cluster.name)")
            } else {
                Button {
                    Task { await model.useContext(for: cluster) }
                } label: {
                    Label("Switch to context", systemImage: "arrow.right.circle")
                }
                .disabled(model.inFlightAction != nil)
                .help("Set kubectl's current-context to \(cluster.name)")
            }
            Button(role: .destructive) {
                Task { await model.deleteCluster(named: cluster.name) }
            } label: {
                Label("Delete cluster", systemImage: "trash")
            }
            .disabled(model.inFlightAction != nil)
        }
    }

    // MARK: - Metrics server

    private var metricsServerCard: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: detail?.metricsServerReady == true
                      ? "chart.line.uptrend.xyaxis.circle.fill"
                      : "chart.line.uptrend.xyaxis.circle")
                    .font(.system(size: 32))
                    .foregroundStyle(detail?.metricsServerReady == true ? .green : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("metrics-server")
                        .font(.headline)
                    Text(metricsStatusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if detail?.metricsServerReady == true {
                    Button(role: .destructive) {
                        Task { await model.uninstallMetricsServer(for: cluster) }
                    } label: {
                        Label("Uninstall", systemImage: "minus.circle")
                    }
                    .disabled(model.inFlightAction != nil)
                } else {
                    Button {
                        Task { await model.installMetricsServer(for: cluster) }
                    } label: {
                        Label("Install metrics-server", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.inFlightAction != nil)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metricsStatusText: String {
        guard let detail = detail else { return "Loading…" }
        if detail.metricsServerReady {
            return "Installed and ready in kube-system."
        }
        return "Not installed. Required for `kubectl top` and HPA."
    }

    // MARK: - Nodes

    private var nodesCard: some View {
        GroupBox("Nodes") {
            if let nodes = detail?.nodes, !nodes.isEmpty {
                VStack(spacing: 0) {
                    ForEach(nodes) { n in
                        nodeRow(n)
                        if n.id != nodes.last?.id { Divider() }
                    }
                }
                .padding(.vertical, 2)
            } else {
                Text(detail?.loading == true ? "Loading…" : "No nodes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Labels

    /// Node labels (same across nodes) for the loaded cluster.
    private var nodeLabels: [String: String]? {
        detail?.nodes.first?.metadata.labels
    }

    /// Wrapping row of node-label pills under the title, plus an add button.
    private var labelsRow: some View {
        FlowLayout(spacing: 6) {
            if let labels = nodeLabels {
                // fleet + region/zone are promoted to the meta line above.
                let rest = AppModel.displayLabels(labels).filter {
                    $0.key != Self.regionLabelKey
                        && $0.key != Self.zoneLabelKey
                        && $0.key != Self.fleetLabelKey
                }
                ForEach(rest, id: \.key) { pair in
                    metaPill(Self.shortLabelKey(pair.key), pair.value)
                }
            }
            addLabelButton
        }
    }

    static let fleetLabelKey = "marina.run/fleet"
    static let regionLabelKey = "topology.kubernetes.io/region"
    static let zoneLabelKey = "topology.kubernetes.io/zone"

    /// Fleet gets a distinct filled badge with the stack icon so it stands out
    /// from the plain grey label pills.
    private func fleetBadge(_ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "square.stack.3d.up.fill")
            Text("fleet").foregroundStyle(.white.opacity(0.75))
            Text(value).bold()
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.blue))
        .help("Fleet: \(value)")
    }

    /// Dashed-blue "Add label" chip — mirrors the New Cluster tile's dashed
    /// border, sized like the label pills so its text aligns with them.
    private var addLabelButton: some View {
        Button {
            newLabelKey = ""
            newLabelValue = ""
            labelError = nil
            showAddLabel = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                Text("Add label")
            }
            .font(.caption)
            .foregroundStyle(.blue)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(
                Capsule().strokeBorder(
                    Color.blue.opacity(0.7),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(model.inFlightAction != nil || (detail?.nodes.isEmpty ?? true))
        .help("Add a node label to every node")
        .popover(isPresented: $showAddLabel, arrowEdge: .bottom) { addLabelForm }
    }

    private var addLabelForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add node label").font(.headline)
            Text("Applied to every node in the cluster.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("key (e.g. marina.run/fleet)", text: $newLabelKey)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitLabel)
            TextField("value", text: $newLabelValue)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitLabel)
            if let labelError {
                Label(labelError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { showAddLabel = false }
                Button("Add") { submitLabel() }
                    .disabled(newLabelKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    /// Validate on Enter/Add: reject invalid Kubernetes label keys/values with
    /// inline feedback; only apply (and close) when the pair is valid.
    private func submitLabel() {
        let key = newLabelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = newLabelValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = Self.validateLabel(key: key, value: value) {
            labelError = error
            return
        }
        labelError = nil
        showAddLabel = false
        Task { await model.addLabel(to: cluster, key: key, value: value) }
    }

    /// Kubernetes label validation (mirrors marina's ValidateLabels): optional
    /// DNS-subdomain prefix + "/" + a ≤63-char name segment; value is empty or a
    /// ≤63-char segment. Returns a human-readable error, or nil when valid.
    static func validateLabel(key: String, value: String) -> String? {
        guard !key.isEmpty else { return "Key is required." }
        let segment = "^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$"
        let name: String
        let slashParts = key.split(separator: "/", omittingEmptySubsequences: false)
        switch slashParts.count {
        case 1:
            name = String(slashParts[0])
        case 2:
            let prefix = String(slashParts[0])
            name = String(slashParts[1])
            let dns = "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$"
            if prefix.isEmpty || prefix.count > 253
                || prefix.range(of: dns, options: .regularExpression) == nil {
                return "Invalid key prefix “\(prefix)”."
            }
        default:
            return "Key may contain at most one “/”."
        }
        if name.isEmpty || name.count > 63
            || name.range(of: segment, options: .regularExpression) == nil {
            return "Invalid key name “\(name)” (letters, digits, -_. ; ≤63 chars)."
        }
        if !value.isEmpty,
           value.count > 63 || value.range(of: segment, options: .regularExpression) == nil {
            return "Invalid value “\(value)” (letters, digits, -_. ; ≤63 chars)."
        }
        return nil
    }

    /// Shorten a label key to its last path segment for compact pills
    /// (marina.run/fleet → fleet, topology.kubernetes.io/region → region).
    static func shortLabelKey(_ key: String) -> String {
        key.split(separator: "/").last.map(String.init) ?? key
    }

    private func nodeRow(_ n: KubeNode) -> some View {
        HStack(alignment: .top) {
            Circle()
                .fill(n.ready ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(n.metadata.name).font(.body.bold())
                HStack(spacing: 10) {
                    if let v = n.status.nodeInfo?.kubeletVersion {
                        Text("kubelet \(v)")
                    }
                    if let arch = n.status.nodeInfo?.architecture {
                        Text(arch)
                    }
                    if let cpu = n.status.capacity?.cpu {
                        Text("cpu \(cpu)")
                    }
                    if let mem = n.status.capacity?.memory {
                        Text("mem \(Self.humanMemory(mem))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let os = n.status.nodeInfo?.osImage {
                    Text(os)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    // MARK: - Pods

    private var podsCard: some View {
        GroupBox("Pods") {
            if let pods = detail?.pods, !pods.isEmpty {
                let byPhase = Dictionary(grouping: pods) { $0.status.phase ?? "Unknown" }
                let byNs = Dictionary(grouping: pods) { $0.metadata.namespace ?? "default" }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ForEach(byPhase.keys.sorted(), id: \.self) { phase in
                            statPill(phase, "\(byPhase[phase]?.count ?? 0)",
                                     color: phaseColor(phase))
                        }
                        Spacer()
                        Text("\(pods.count) pods total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Namespace")
                            Spacer()
                            Text("Pods")
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        ForEach(byNs.keys.sorted(), id: \.self) { ns in
                            HStack {
                                Text(ns).font(.callout.monospaced())
                                Spacer()
                                Text("\(byNs[ns]?.count ?? 0)")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(4)
            } else {
                Text(detail?.loading == true ? "Loading…" : "No pods.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }

    private func phaseColor(_ phase: String) -> Color {
        switch phase {
        case "Running": return .green
        case "Pending": return .orange
        case "Succeeded": return .blue
        case "Failed": return .red
        default: return .gray
        }
    }

    // MARK: - Local DNS

    private func localDNSCard(zone: String) -> some View {
        let names = model.dnsRecords(in: cluster.name)
        let state = detail?.externalDNS
        let unrouted = model.clustersWithUnroutedRecords.contains(cluster.name)
        let ingressDrift = model.ingressSourceDrift(for: cluster.name) == true
        let stale = unrouted || ingressDrift
        return GroupBox("Local DNS") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(verbatim: "*.\(zone)")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    if state != .missing {
                        Text("\(names.count) name\(names.count == 1 ? "" : "s") published")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let fleetZone = model.fleetZone(for: cluster.name) {
                    HStack(spacing: 8) {
                        Text(verbatim: "*.\(fleetZone)")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        Text("fleet zone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Shared by every member of the fleet. Names land here only through the external-dns.kubernetes.io/hostname annotation; the first member to publish a name owns it.")
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: externalDNSSymbol(state))
                        .foregroundStyle(externalDNSTint(state))
                        .imageScale(.small)
                    Text(externalDNSText(state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if state == .missing || stale {
                        Button {
                            confirmAttach = true
                        } label: {
                            Label(state == .missing ? "Attach" : "Re-attach", systemImage: "link")
                        }
                        .controlSize(.small)
                        .disabled(model.inFlightAction != nil)
                    }
                }
                if ingressDrift {
                    Label(model.dnsIngressEnabled
                          ? "network.dns.ingress is on, but this cluster's ExternalDNS was installed without the Ingress source. Re-attach to publish Ingress hosts."
                          : "This cluster's ExternalDNS still publishes Ingress hosts (installed before marina 0.3.0 or with network.dns.ingress on). Re-attach to remove those names; to keep one, put an external-dns.kubernetes.io/hostname annotation on the ingress controller's Service.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if unrouted {
                    Label("Some names here point at pod IPs the Mac can't reach. An ExternalDNS installed by marina 0.2.0 published every Service type, headless ones included; re-attaching limits it to LoadBalancer Services and removes the extras.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let ca = model.localCA, ca.enabled {
                    Divider()
                    tlsRows(ca)
                }
            }
            .padding(6)
        }
        .confirmationDialog(
            "\(state == .missing ? "Attach" : "Re-attach") \(cluster.name) to local DNS?",
            isPresented: $confirmAttach
        ) {
            Button(state == .missing ? "Attach" : "Re-attach") {
                Task { await model.attachLocalDNS(to: cluster.name) }
            }
        } message: {
            Text("Runs `marina dns attach \(cluster.name)`: installs or updates ExternalDNS and re-applies the cluster's CoreDNS config, then restarts CoreDNS. In-cluster DNS is briefly interrupted.")
        }
        .confirmationDialog(
            "Issue a TLS wildcard for \(cluster.name)?",
            isPresented: $confirmCAAttach
        ) {
            Button("Issue wildcard") {
                Task { await model.attachLocalCA(to: cluster) }
            }
        } message: {
            Text("Runs `marina ca attach \(cluster.name)`: issues *.\(zone) (and the fleet's wildcard) into default/marina-wildcard-tls, adds the root CA to every node's trust store, and creates a marina-ca ClusterIssuer if cert-manager is installed. Installing the root restarts the nodes' containerd.")
        }
    }

    // MARK: - Local CA

    @ViewBuilder
    private func tlsRows(_ ca: LocalCAStatus) -> some View {
        let fleet = model.fleet(of: cluster.name)
        let issued = ca.cluster(cluster.name)
        if let issued {
            wildcardRow(issued, secret: "default/marina-wildcard-tls", fleet: false)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "lock.slash")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Text("No TLS wildcard yet: this cluster was created before the local CA existed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    confirmCAAttach = true
                } label: {
                    Label("Issue wildcard", systemImage: "lock")
                }
                .controlSize(.small)
                .disabled(model.inFlightAction != nil)
            }
        }
        if let fleet, let fleetIssued = ca.fleet(fleet) {
            wildcardRow(fleetIssued, secret: "default/marina-fleet-wildcard-tls", fleet: true)
        }
        if ca.exists, !ca.trusted {
            Label("This Mac doesn't trust the marina root CA yet, so browsers reject these certificates. Run `marina ca trust` in a terminal (it needs sudo).",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func wildcardRow(_ zone: LocalCAStatus.Zone, secret: String, fleet: Bool) -> some View {
        let days = zone.notAfter.flatMap(Self.daysUntil)
        let renewSoon = (days ?? .max) <= 30
        return HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .foregroundStyle(renewSoon ? .orange : .green)
                .imageScale(.small)
            Text(verbatim: zone.wildcard)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Text(verbatim: secret)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            if let notAfter = zone.notAfter {
                Text("expires \(notAfter)")
                    .font(.caption)
                    .foregroundStyle(renewSoon ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            }
            Spacer()
            if renewSoon {
                Button {
                    confirmCAAttach = true
                } label: {
                    Label("Renew", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(model.inFlightAction != nil)
                .help("marina ca attach re-issues a wildcard within 30 days of expiry")
            }
            Menu {
                ForEach(secretTargetNamespaces, id: \.self) { ns in
                    Button(ns) {
                        Task { await model.copyWildcardSecret(from: cluster, to: ns, fleet: fleet) }
                    }
                }
            } label: {
                Label("Copy to namespace", systemImage: "doc.on.doc")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
            .disabled(model.inFlightAction != nil || secretTargetNamespaces.isEmpty)
            .help("marina ca secret: an Ingress reads its TLS Secret from its own namespace. Re-run after the wildcard is renewed.")
        }
    }

    /// Namespaces that run pods, minus `default` (where the Secret already is)
    /// and the system ones nobody terminates TLS in.
    private var secretTargetNamespaces: [String] {
        let skip: Set<String> = ["default", "kube-system", "kube-public", "kube-node-lease",
                                 "local-path-storage", "metallb-system", "external-dns"]
        return Set((detail?.pods ?? []).compactMap(\.metadata.namespace))
            .subtracting(skip)
            .sorted()
    }

    static func daysUntil(_ date: String) -> Int? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        guard let d = f.date(from: date) else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: d).day
    }

    private func externalDNSText(_ state: ExternalDNSState?) -> String {
        switch state {
        case .ready: return "ExternalDNS publishes this cluster's LoadBalancer Services as <service>.<namespace> under this zone."
        case .notReady: return "ExternalDNS is installed but not ready yet."
        case .missing: return "Not attached: this cluster was created before local DNS was on, or the install failed. Its Services have no names."
        case nil: return detail?.loading == true ? "Checking ExternalDNS…" : "Couldn't read ExternalDNS state."
        }
    }

    private func externalDNSSymbol(_ state: ExternalDNSState?) -> String {
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .notReady: return "clock.fill"
        case .missing: return "exclamationmark.triangle.fill"
        case nil: return "questionmark.circle"
        }
    }

    private func externalDNSTint(_ state: ExternalDNSState?) -> Color {
        switch state {
        case .ready: return .green
        case .notReady, .missing: return .orange
        case nil: return .secondary
        }
    }

    // MARK: - Kubeconfig

    private var kubeconfigCard: some View {
        GroupBox("Kubeconfig") {
            VStack(alignment: .leading, spacing: 6) {
                Text(cluster.kubeconfigPath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button {
                        copy("export KUBECONFIG=\(cluster.kubeconfigPath)")
                    } label: {
                        Label("Copy export command", systemImage: "doc.on.doc")
                    }
                    Spacer()
                }
            }
            .padding(6)
        }
    }

    private func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    /// Format a k8s memory quantity (e.g. "16307012Ki") as a readable GiB/MiB
    /// string. Falls back to the raw value if it can't be parsed.
    static func humanMemory(_ raw: String) -> String {
        guard let mib = QuantityParser.memoryMiB(raw) else { return raw }
        if mib >= 1024 {
            return String(format: "%.1f GiB", mib / 1024)
        }
        return String(format: "%.0f MiB", mib)
    }

    // MARK: - Bits

    private func errorBanner(_ err: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(err)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.15))
        )
    }

    private func metaPill(_ k: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(k).foregroundStyle(.secondary)
            Text(v).bold()
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.secondary.opacity(0.12))
        )
    }

    private func statPill(_ label: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
            Text(value).bold()
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.secondary.opacity(0.10))
        )
    }
}
