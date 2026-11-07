import AppKit
import SwiftUI

/// Deployments, StatefulSets, DaemonSets, Jobs and CronJobs of one cluster,
/// each expandable to its pods, with logs and two actions (rollout restart,
/// delete pod). Read-mostly on purpose: anything deeper belongs in kubectl,
/// k9s or Headlamp.
struct WorkloadsTabView: View {
    let cluster: KindCluster

    @State private var snapshot = WorkloadSnapshot()
    @State private var loaded = false
    @State private var loading = false
    @State private var error: String?
    @State private var namespace: String = Self.allNamespaces
    @State private var showSystem = false
    @State private var expanded: Set<String> = []
    @State private var logSource: PodLogsView.Source?
    @State private var pendingRestart: Workload?
    @State private var pendingDelete: WorkloadPod?
    @State private var actionMessage: String?
    /// Re-read every 5 s while the tab is visible ("watch", by polling: one
    /// kubectl round trip, no long-lived watch streams to manage).
    @State private var live = true

    private static let allNamespaces = "__all__"
    /// Namespaces kind, marina and their addons own. Hidden unless asked for.
    private static let systemNamespaces: Set<String> = [
        "kube-system", "kube-public", "kube-node-lease", "local-path-storage",
        "metallb-system", "external-dns", "cert-manager",
    ]

    private var kube: KubeClient { KubeClient(kubeconfigPath: cluster.kubeconfigPath) }

    private func isVisible(_ ns: String) -> Bool {
        if namespace != Self.allNamespaces { return ns == namespace }
        return showSystem || !Self.systemNamespaces.contains(ns)
    }

    private var namespaces: [String] {
        let all = Set(snapshot.workloads.compactMap(\.metadata.namespace)
                      + snapshot.orphanPods.map(\.namespace))
        return all.filter { showSystem || !Self.systemNamespaces.contains($0) }.sorted()
    }

    private var visibleWorkloads: [Workload] {
        snapshot.workloads
            .filter { isVisible($0.metadata.namespace ?? "default") }
            .sorted {
                let (a, b) = ($0.metadata.namespace ?? "", $1.metadata.namespace ?? "")
                if a != b { return a < b }
                let (ka, kb) = (Workload.listedKinds.firstIndex(of: $0.kind) ?? 9,
                                Workload.listedKinds.firstIndex(of: $1.kind) ?? 9)
                return ka != kb ? ka < kb : $0.metadata.name < $1.metadata.name
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolbar
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            if let actionMessage {
                Label(actionMessage, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !loaded && loading {
                ProgressView("Reading workloads…")
            } else {
                summary
                workloadsCard
                if !visibleOrphans.isEmpty { orphansCard }
            }
        }
        .task(id: "\(cluster.name)|\(live)") {
            await load()
            while live && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                await load()
            }
        }
        .sheet(item: $logSource) { src in
            PodLogsView(kubeconfigPath: cluster.kubeconfigPath, source: src)
        }
        .confirmationDialog(
            "Restart \(pendingRestart?.kind ?? "") \(pendingRestart?.metadata.name ?? "")?",
            isPresented: Binding(get: { pendingRestart != nil }, set: { if !$0 { pendingRestart = nil } }),
            presenting: pendingRestart
        ) { w in
            Button("Rollout Restart") { Task { await restart(w) } }
        } message: { _ in
            Text("Runs kubectl rollout restart: pods are replaced one by one, following the update strategy.")
        }
        .confirmationDialog(
            "Delete pod \(pendingDelete?.metadata.name ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { p in
            Button("Delete Pod", role: .destructive) { Task { await delete(p) } }
        } message: { p in
            Text(p.metadata.controllerRef == nil
                 ? "This pod has no controller: it will not be recreated."
                 : "Its controller creates a replacement.")
        }
    }

    // MARK: - Toolbar & summary

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Namespace", selection: $namespace) {
                Text("All namespaces").tag(Self.allNamespaces)
                Divider()
                ForEach(namespaces, id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 280)
            Toggle("System namespaces", isOn: $showSystem)
                .toggleStyle(.checkbox)
                .help("kube-system, metallb-system, external-dns, local-path-storage…")
            Spacer()
            Toggle(isOn: $live) {
                Label("Live", systemImage: live ? "dot.radiowaves.left.and.right" : "pause.circle")
            }
            .toggleStyle(.button)
            .tint(live ? .green : nil)
            .help(live ? "Refreshing every 5 seconds — click to pause" : "Paused — click to refresh every 5 seconds")
            if loading { ProgressView().controlSize(.small) }
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Re-read workloads and pods")
                .disabled(loading)
        }
        .controlSize(.small)
        .onChange(of: showSystem) { _, on in
            if !on, Self.systemNamespaces.contains(namespace) { namespace = Self.allNamespaces }
        }
    }

    private var summary: some View {
        let ws = visibleWorkloads
        let byKind = Dictionary(grouping: ws, by: \.kind)
        let pods = ws.flatMap { snapshot.podsByWorkload[$0.id] ?? [] } + visibleOrphans
        let unhealthy = pods.filter { !$0.healthy }.count
        let restarts = pods.reduce(0) { $0 + $1.restarts }
        return HStack(spacing: 8) {
            ForEach(Workload.listedKinds, id: \.self) { k in
                if let n = byKind[k]?.count { pill(plural(k, n), "\(n)") }
            }
            Spacer()
            pill("pods", "\(pods.count)")
            if unhealthy > 0 { pill("not running", "\(unhealthy)", color: .orange) }
            if restarts > 0 { pill("restarts", "\(restarts)", color: .orange) }
        }
        .font(.callout)
    }

    private func plural(_ kind: String, _ n: Int) -> String {
        n == 1 ? kind : (kind.hasSuffix("s") ? kind : kind + "s")
    }

    // MARK: - Workloads

    private var workloadsCard: some View {
        GroupBox {
            if visibleWorkloads.isEmpty {
                Text(showSystem ? "No workloads." : "No workloads outside the system namespaces.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    ForEach(visibleWorkloads) { w in
                        Divider()
                        workloadRow(w)
                        if expanded.contains(w.id) {
                            podsList(snapshot.podsByWorkload[w.id] ?? [])
                                .padding(.leading, 22)
                                .padding(.bottom, 6)
                        }
                    }
                }
                .padding(4)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Kind").frame(width: 92, alignment: .leading)
            Text("Ready").frame(width: 92, alignment: .leading)
            Text("Age").frame(width: 56, alignment: .trailing)
            Color.clear.frame(width: 64)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.bottom, 4)
    }

    private func workloadRow(_ w: Workload) -> some View {
        let pods = snapshot.podsByWorkload[w.id] ?? []
        let (ready, health) = w.readiness
        return HStack(spacing: 8) {
            Button {
                if expanded.contains(w.id) { expanded.remove(w.id) } else { expanded.insert(w.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded.contains(w.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                    Circle().fill(color(health)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(w.metadata.name).font(.callout.monospaced()).lineLimit(1)
                        Text(w.metadata.namespace ?? "").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(pods.isEmpty ? "No pods" : "\(pods.count) pod\(pods.count == 1 ? "" : "s")")

            Text(w.kind).font(.caption).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            Text(ready).font(.callout.monospacedDigit()).foregroundStyle(color(health) == .green ? .primary : color(health))
                .frame(width: 92, alignment: .leading)
            age(w.metadata.createdAt).frame(width: 56, alignment: .trailing)
            HStack(spacing: 6) {
                if let sel = w.podSelector, !pods.isEmpty {
                    Button {
                        logSource = .workload(name: w.metadata.name, kind: w.kind,
                                              namespace: w.metadata.namespace ?? "default", selector: sel)
                    } label: { Image(systemName: "text.alignleft") }
                        .help("Logs of every pod and container (kubectl logs -l \(sel) --prefix)")
                }
                if w.restartable {
                    Button { pendingRestart = w } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                        .help("Rollout restart")
                }
            }
            .buttonStyle(.borderless)
            .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    private func podsList(_ pods: [WorkloadPod]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if pods.isEmpty {
                Text("No pods.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(pods.sorted { $0.metadata.name < $1.metadata.name }) { p in
                podRow(p)
            }
        }
    }

    private func podRow(_ p: WorkloadPod) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "cube").font(.caption2).foregroundStyle(.secondary)
            Text(p.metadata.name).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Text(p.displayStatus)
                .font(.caption)
                .foregroundStyle(p.healthy ? Color.secondary : Color.orange)
                .frame(width: 120, alignment: .leading)
            Text(p.readyText).font(.caption.monospacedDigit()).frame(width: 40, alignment: .leading)
            Text(p.restarts > 0 ? "↻ \(p.restarts)" : "")
                .font(.caption.monospacedDigit()).foregroundStyle(.orange)
                .frame(width: 44, alignment: .leading)
                .help("Container restarts")
            Text(p.spec?.nodeName ?? "").font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).frame(width: 150, alignment: .leading)
            HStack(spacing: 6) {
                Button { logSource = .pod(p) } label: { Image(systemName: "text.alignleft") }
                    .help("Logs")
                Menu {
                    Button("Copy kubectl exec command") {
                        let c = p.spec?.containers?.first?.name ?? ""
                        copy("kubectl --kubeconfig \(cluster.kubeconfigPath) exec -it -n \(p.namespace) \(p.metadata.name) -c \(c) -- sh")
                    }
                    Button("Copy kubectl logs command") {
                        copy("kubectl --kubeconfig \(cluster.kubeconfigPath) logs -f -n \(p.namespace) \(p.metadata.name)")
                    }
                    Divider()
                    Button("Delete Pod…", role: .destructive) { pendingDelete = p }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
    }

    private var visibleOrphans: [WorkloadPod] {
        snapshot.orphanPods.filter { isVisible($0.namespace) }
    }

    private var orphansCard: some View {
        GroupBox("Other pods (static, bare)") {
            podsList(visibleOrphans).padding(4)
        }
    }

    // MARK: - Actions

    private func load() async {
        loading = true
        defer { loading = false; loaded = true }
        do {
            async let objects = kube.listWorkloadObjects()
            async let pods = kube.listWorkloadPods()
            snapshot = WorkloadSnapshot.build(objects: try await objects, pods: try await pods)
            error = nil
            if namespace != Self.allNamespaces, !namespaces.contains(namespace) {
                namespace = Self.allNamespaces
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restart(_ w: Workload) async {
        do {
            let out = try await kube.rolloutRestart(kind: w.kind, namespace: w.metadata.namespace ?? "default",
                                                     name: w.metadata.name)
            actionMessage = out.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            self.error = error.localizedDescription
        }
        try? await Task.sleep(for: .seconds(1))
        await load()
    }

    private func delete(_ p: WorkloadPod) async {
        do {
            let out = try await kube.deletePod(namespace: p.namespace, name: p.metadata.name)
            actionMessage = out.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            self.error = error.localizedDescription
        }
        try? await Task.sleep(for: .seconds(1))
        await load()
    }

    // MARK: - Bits

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        actionMessage = "Copied to the clipboard."
    }

    private func color(_ h: Workload.Health) -> Color {
        switch h {
        case .ok: return .green
        case .progressing: return .orange
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    @ViewBuilder
    private func age(_ date: Date?) -> some View {
        if let date {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                Text(RelativeAge.format(since: date, now: ctx.date))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else {
            Text("")
        }
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
}

extension PodLogsView.Source: Identifiable {
    var id: String {
        switch self {
        case .pod(let p): return "pod/" + p.id
        case .workload(let name, let kind, let ns, _): return "\(kind)/\(ns)/\(name)"
        case .docker(let id, _): return "docker/" + id
        }
    }
}
