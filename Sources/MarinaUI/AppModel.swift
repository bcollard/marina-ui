import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    /// User preferences (visibility toggles + poll cadences). The poll loops
    /// read the cadence off this on every iteration, so changes take effect on
    /// the next cycle without restarting anything.
    let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    // The single marina VM. Marina is designed around exactly one instance at a time.
    var vm: Instance?
    var config: MarinaConfig?
    var marinaVersion: String?

    // VM live state (probed over SSH when running).
    var guestStats: GuestSSH.GuestStats?
    var guestLima0IP: String?
    private var fetchingGuestOSInfo = false
    private var fetchingGuestDiskUsage = false

    var clusters: [KindCluster] = []
    var clustersLoading = false
    var clustersError: String?

    // kubectl's current-context (from the default kubeconfig). marina names each
    // cluster's context after the cluster, so this both badges the active cluster
    // in the sidebar and may hold a non-marina context (shown in the footer).
    // Refreshed on refreshAll() and after a context switch.
    var currentKubeContext: String?

    // Cluster creation timestamps, sourced from the kube-system namespace.
    // Cached because creation time never changes for a given cluster.
    var clusterCreatedAt: [String: Date] = [:]
    private var creationTimeTask: Task<Void, Never>?

    // Node labels per cluster (read from the first node), for fleet/topology
    // display. marina applies managed-by, marina.run/fleet, and topology labels.
    var clusterLabels: [String: [String: String]] = [:]
    private var labelsTask: Task<Void, Never>?

    // Kubelet version reported by each cluster's first node — the real
    // Kubernetes version the kind nodes run, as opposed to the kindest/node tag
    // configured in config.yaml (which only applies to clusters created since).
    // Populated by the same node fetch that reads labels.
    var clusterNodeVersion: [String: String] = [:]

    /// How a container's bind mount resolves, for the mount rows in its detail
    /// view. Docker resolves a bind source *inside the guest*, so a source that
    /// falls outside every shared directory is not the Mac's copy of that path:
    /// dockerd created it empty in the VM and the container sees nothing.
    enum MountBacking: Sendable, Hashable {
        /// Reaches the Mac through this share.
        case hostShare(MarinaStatus.Mounts.Share)
        /// Guest-only: the path exists in the VM, but not as your Mac's.
        case guestOnly
        /// A docker volume, or a path we can't judge — not a host bind at all.
        case notApplicable
        /// marina is too old to report its mounts, so we must not guess.
        case unknown
    }

    func backing(for mount: DockerContainer.MountDetail) -> MountBacking {
        guard mount.isBind else { return .notApplicable }
        guard let hostMounts else { return .unknown }
        if let share = hostMounts.share(backing: mount.source) { return .hostShare(share) }
        return .guestOnly
    }

    /// Fleet a cluster belongs to (marina.run/fleet node label), if any.
    func fleet(of clusterName: String) -> String? {
        clusterLabels[clusterName]?["marina.run/fleet"]
    }

    /// Clusters bucketed by fleet: fleets first (alphabetically), clusters with
    /// no fleet last, each bucket keeping `clusters`' order.
    var clusterGroups: [ClusterGroup] {
        var byFleet: [String: [KindCluster]] = [:]
        var ungrouped: [KindCluster] = []
        for c in clusters {
            if let f = fleet(of: c.name) {
                byFleet[f, default: []].append(c)
            } else {
                ungrouped.append(c)
            }
        }
        var groups = byFleet
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { ClusterGroup(fleet: $0.key, clusters: $0.value) }
        if !ungrouped.isEmpty {
            groups.append(ClusterGroup(fleet: nil, clusters: ungrouped))
        }
        return groups
    }

    /// True while some cluster's node labels haven't been fetched, so its fleet
    /// membership is unknown to the UI (marina itself still knows).
    var hasClustersWithUnknownFleet: Bool {
        clusters.contains { clusterLabels[$0.name] == nil }
    }

    /// marina-relevant labels for display — drops the noisy Kubernetes system
    /// labels (hostname/os/arch/roles), keeps fleet, topology, managed-by, and
    /// any custom labels.
    static func displayLabels(_ all: [String: String]) -> [(key: String, value: String)] {
        let systemPrefixes = [
            "kubernetes.io/", "beta.kubernetes.io/",
            "node-role.kubernetes.io/", "node.kubernetes.io/",
        ]
        return all
            .filter { key, _ in !systemPrefixes.contains(where: { key.hasPrefix($0) }) }
            .map { (key: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }
    }

    var selection: SidebarSelection?

    // Per-selected-cluster details (rebuilt on selection change).
    var clusterDetail: ClusterDetail?

    // Time-series metrics per cluster (persists across selection changes).
    var metricsHistory: [String: MetricsHistory] = [:]
    var latestPods: [String: [PodMetric]] = [:]
    // cluster name -> pod id ("ns/name") -> sample ring buffer.
    var podHistory: [String: [String: PodMetricsHistory]] = [:]
    var metricsError: [String: String] = [:]
    private var metricsTask: Task<Void, Never>?

    // TCP probe results: cluster.name -> "ip:port" -> result.
    var serviceProbes: [String: [String: ProbeResult]] = [:]
    private var probeTask: Task<Void, Never>?

    struct ProbeResult: Sendable, Hashable {
        let timestamp: Date
        let isOpen: Bool
    }

    // VM CPU/memory history (host-VM-level, polled while VM is running).
    var vmHistory = VMHistory()
    private var vmPollTask: Task<Void, Never>?
    private var lastVMRaw: GuestRawSample?

    // Background poll that detects out-of-band changes (VM started/stopped,
    // clusters created/deleted via the CLI) and refreshes the UI to match.
    private var statePollTask: Task<Void, Never>?

    // `marina doctor` report, shown in the Settings window's Diagnostics tab.
    // Run on demand only — the checks shell out to sudo-less `route`/`ssh`
    // probes that are far too heavy for a poll loop.
    var doctorReport: DoctorReport?
    var doctorError: String?
    var doctorRunning = false
    var doctorRanAt: Date?

    // Containers running in the guest VM, split into the ones marina manages
    // (kind nodes, registry mirrors) and everything else. Fetched only while
    // the "Docker containers" preference is on.
    var containers: [DockerContainer] = []
    var containersError: String?
    var containersLoading = false
    /// Tail of `docker logs` per container id, populated on demand.
    var containerLogs: [String: String] = [:]

    // Host directories shared into the guest, from `marina status`. This is the
    // Lima instance's live list — not what config.yaml asks for — which is what
    // makes it usable for deciding whether a container's bind actually reaches
    // the Mac. nil when the marina CLI predates the feature (0.1.59).
    var hostMounts: MarinaStatus.Mounts?

    // Local DNS zone state from the same `marina status` call. nil when marina
    // predates `network.dns` (0.2.0), which hides every DNS feature.
    var localDNS: MarinaStatus.DNS?
    // Every name in the zone (`marina dns list`). nil until fetched, or while
    // the zone is off / the VM is down.
    var dnsRecords: [LocalDNSRecord]?
    var dnsRecordsError: String?
    // How each published name resolves on the Mac: cluster -> name -> result.
    var nameResolutions: [String: [String: NameResolution]] = [:]
    private var resolveTask: Task<Void, Never>?

    // Whether macOS's resolver answers for the zone (marina-probe.<domain>).
    // nil until checked, or while the zone is off / the DNS server is down.
    var systemResolver: SystemResolverState?
    private var systemResolverTask: Task<Void, Never>?

    // Local CA (`marina ca status`): root trust and which clusters/fleets hold
    // a wildcard. nil when `network.dns.tls` is off or marina predates it.
    var localCA: LocalCAStatus?

    /// What `network.dns.ingress` asks for (off unless set, marina 0.3.0+).
    var dnsIngressEnabled: Bool { config?.network?.dns?.ingress == true }

    /// The cluster's ExternalDNS publishes Ingress hosts when the config says
    /// it shouldn't, or the reverse. Only `marina dns attach` re-renders it, so
    /// a cluster attached before 0.3.0 keeps the ingress source after an
    /// upgrade. nil when the deployment hasn't been read.
    func ingressSourceDrift(for clusterName: String) -> Bool? {
        guard let detail = clusterDetail, detail.cluster.name == clusterName,
              detail.externalDNS != .missing, let deployed = detail.externalDNSIngress
        else { return nil }
        return deployed != dnsIngressEnabled
    }

    /// The subzone a cluster publishes into, when the zone is on.
    func dnsZone(for clusterName: String) -> String? {
        localDNS?.zone(for: clusterName)
    }

    /// The fleet zone `<fleet>.<domain>` a cluster's ExternalDNS also owns
    /// (marina 0.2.3+). Names land there only through the hostname annotation.
    func fleetZone(for clusterName: String) -> String? {
        guard let fleet = fleet(of: clusterName) else { return nil }
        return localDNS?.zone(for: fleet)
    }

    /// The automatic name marina's ExternalDNS gives a Service:
    /// `network.dns.nameTemplate` (default `{{.Name}}.{{.Namespace}}`) plus the
    /// cluster zone. nil when the template uses fields we can't render here
    /// (`.Labels`, `.Annotations`) — then no name is singled out.
    func automaticName(for service: KubeService, in clusterName: String) -> String? {
        guard let zone = dnsZone(for: clusterName) else { return nil }
        var name = config?.network?.dns?.nameTemplate ?? "{{.Name}}.{{.Namespace}}"
        for (field, value) in [("Name", service.metadata.name),
                               ("Namespace", service.metadata.namespace ?? "default")] {
            name = name.replacingOccurrences(of: "{{.\(field)}}", with: value)
                .replacingOccurrences(of: "{{ .\(field) }}", with: value)
        }
        return name.contains("{{") ? nil : "\(name).\(zone)"
    }

    /// Names that point at one of this Service's VIPs, in its cluster zone or
    /// its fleet zone, most deliberate first: the Service's own hostname
    /// annotation, then other names on the VIP (Ingress hosts), then the
    /// automatic name — `--combine-fqdn-annotation` keeps publishing it next
    /// to a custom one, but nobody chose it.
    func dnsNames(for service: KubeService, in clusterName: String) -> [LocalDNSRecord] {
        guard let dnsRecords else { return [] }
        let zones = [dnsZone(for: clusterName), fleetZone(for: clusterName)].compactMap { $0 }
        guard !zones.isEmpty else { return [] }
        let ips = Set(service.externalIPs)
        let annotated = Set(service.hostnameAnnotation)
        let automatic = automaticName(for: service, in: clusterName)
        func rank(_ name: String) -> Int {
            annotated.contains(name) ? 0 : name == automatic ? 2 : 1
        }
        return dnsRecords
            .filter { rec in ips.contains(rec.ip) && zones.contains { rec.name.hasSuffix("." + $0) } }
            .sorted { a, b in
                let (ra, rb) = (rank(a.name), rank(b.name))
                return ra != rb ? ra < rb : a.name < b.name
            }
    }

    /// Where a published name comes from, for the Services tab.
    func dnsNameSource(_ name: String, for service: KubeService, in clusterName: String) -> DNSNameSource {
        if service.hostnameAnnotation.contains(name) { return .annotation }
        if name == automaticName(for: service, in: clusterName) { return .automatic }
        return .sharedVIP
    }

    /// Published names in a cluster's own subzone.
    func dnsRecords(in clusterName: String) -> [LocalDNSRecord] {
        guard let zone = dnsZone(for: clusterName) else { return [] }
        return (dnsRecords ?? []).filter { $0.name.hasSuffix("." + zone) }
    }

    /// Whether a name falls under a fleet zone rather than the cluster's own.
    func isFleetName(_ name: String, in clusterName: String) -> Bool {
        guard let zone = fleetZone(for: clusterName) else { return false }
        return name.hasSuffix("." + zone)
    }

    /// The marina wildcard that covers a name, when one has been issued. A
    /// wildcard covers one label, so a default two-label automatic name isn't.
    func wildcardCoverage(for name: String, in clusterName: String) -> WildcardCoverage? {
        guard let localCA else { return nil }
        if let zone = dnsZone(for: clusterName), let issued = localCA.cluster(clusterName),
           WildcardCoverage.isOneLabel(name, under: zone) {
            return .cluster(wildcard: issued.wildcard)
        }
        if let fleet = fleet(of: clusterName), let zone = fleetZone(for: clusterName),
           let issued = localCA.fleet(fleet), WildcardCoverage.isOneLabel(name, under: zone) {
            return .fleet(wildcard: issued.wildcard)
        }
        return nil
    }

    /// Whether the Mac has a route to an address: marina routes only the kind
    /// bridge CIDR to the VM. nil when the CIDR isn't known.
    func isRoutable(_ ip: String) -> Bool? {
        guard let cidr = config?.network?.kindBridgeCIDR.flatMap(IPv4CIDR.init) else { return nil }
        return cidr.contains(ip)
    }

    /// Records whose address is outside the kind bridge: the name resolves,
    /// but nothing on the Mac can reach it.
    var unroutedDNSRecords: [LocalDNSRecord] {
        (dnsRecords ?? []).filter { isRoutable($0.ip) == false }
    }

    /// Clusters whose zone holds unroutable records. marina 0.2.0's ExternalDNS
    /// published every Service type — headless ones with pod IPs; 0.2.1 limits
    /// it to LoadBalancer, but only for clusters (re)attached since, and
    /// `policy=sync` then drops the extras.
    var clustersWithUnroutedRecords: [String] {
        let unrouted = unroutedDNSRecords
        return clusters.map(\.name).filter { name in
            guard let zone = dnsZone(for: name) else { return false }
            return unrouted.contains { $0.name.hasSuffix("." + zone) }
        }
    }

    // Registry mirror disk-usage measurements, keyed by mirror name.
    var mirrorCacheSizes: [String: MirrorCacheSize] = [:]

    enum MirrorCacheSize: Sendable, Hashable {
        case measuring
        case measured(bytes: Int64, tags: Int?, repos: Int?, path: String)
        case missing(path: String)
        case storedInGuest
    }

    var inFlightAction: String?

    // Completed-action logs, scoped so each view shows only what's relevant to
    // it, plus an aggregated console transcript. Newest entry is last.
    private(set) var logRecords: [LogRecord] = []
    private static let maxLogRecords = 200

    /// Append a completed action's log under a scope, capping history.
    private func appendLog(scope: LogScope, label: String, text: String) {
        logRecords.append(LogRecord(date: Date(), scope: scope, label: label, text: text))
        if logRecords.count > Self.maxLogRecords {
            logRecords.removeFirst(logRecords.count - Self.maxLogRecords)
        }
    }

    /// Most recent log entry for a scope (drives a view's "Last action" card).
    func latestLog(for scope: LogScope) -> LogRecord? {
        logRecords.last { $0.scope == scope }
    }

    /// Most recent log entry matching any of the given scopes.
    func latestLog(forAny scopes: [LogScope]) -> LogRecord? {
        logRecords.last { scopes.contains($0.scope) }
    }

    /// All records rendered as one timestamped transcript (oldest first) for
    /// the aggregated console panel.
    var consoleTranscript: String {
        logRecords.map { rec in
            "[\(Self.logTime.string(from: rec.date))] \(rec.label)\n\(rec.text)"
        }.joined(separator: "\n")
    }

    func clearLog() { logRecords.removeAll() }

    private static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // Live `marina cluster create` session. Present from the moment the user
    // confirms creation until they navigate away (or it's superseded). Drives
    // the placeholder card/row in the lists and the streaming log view.
    var creation: Creation?

    struct Creation: Sendable {
        var name: String
        var log: String = ""
        var running: Bool = true
        var failed: Bool = false
        var cancelled: Bool = false
        /// marina's own "non-default kind node version — UNSUPPORTED" warning,
        /// surfaced verbatim when it appears in the create output.
        var versionWarning: String?
    }

    // The in-flight streaming create loop, so it can be cancelled mid-run.
    private var creationTask: Task<Void, Never>?

    /// Name of a cluster currently being provisioned that isn't in `clusters`
    /// yet — used to render a placeholder in the sidebar and overview.
    var provisioningClusterName: String? {
        guard let creation, !clusters.contains(where: { $0.name == creation.name })
        else { return nil }
        return creation.name
    }

    struct ClusterDetail: Sendable {
        var cluster: KindCluster
        var nodes: [KubeNode] = []
        var pods: [KubePod] = []
        var services: [KubeService] = []
        var metricsServerReady: Bool = false
        /// nil when the zone is off, or kubectl couldn't tell.
        var externalDNS: ExternalDNSState? = nil
        /// Whether that ExternalDNS runs `--source=ingress`; nil when unknown.
        var externalDNSIngress: Bool? = nil
        var serverVersion: String? = nil
        var loading: Bool = true
        var error: String? = nil
    }

    var selectedCluster: KindCluster? {
        if case .cluster(let name) = selection {
            return clusters.first { $0.name == name }
        }
        return nil
    }

    var selectedMirror: MarinaConfig.Registries.Mirror? {
        if case .mirror(let name) = selection {
            return config?.registries?.mirrors?.first { $0.name == name }
        }
        return nil
    }

    var selectedContainer: DockerContainer? {
        if case .container(let id) = selection {
            return containers.first { $0.id == id }
        }
        return nil
    }

    var mirrors: [MarinaConfig.Registries.Mirror] {
        config?.registries?.mirrors ?? []
    }

    private var mirrorNames: Set<String> { Set(mirrors.map(\.name)) }

    /// Containers marina doesn't own — everything that isn't a kind node, a
    /// pull-through mirror or the local DNS server. Running first, then most
    /// recently created.
    var unmanagedContainers: [DockerContainer] {
        let names = mirrorNames
        return containers
            .filter { $0.managed(mirrorNames: names) == nil }
            .sorted(by: Self.displayOrder)
    }

    /// The same containers bucketed by `com.docker.compose.project`, compose
    /// stacks first (alphabetically), standalone containers last.
    ///
    /// A stack is a unit the user thinks about as a whole — its members share a
    /// lifecycle and a compose file — so showing five rows of
    /// `myapp-worker-{1..5}` flat next to an unrelated container hides the one
    /// fact that matters about them.
    var containerGroups: [ContainerGroup] {
        var byProject: [String: [DockerContainer]] = [:]
        var standalone: [DockerContainer] = []
        for c in unmanagedContainers {
            if let project = c.compose?.project {
                byProject[project, default: []].append(c)
            } else {
                standalone.append(c)
            }
        }
        var groups = byProject
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { project, members in
                // Within a stack, order by service then replica — a stack's
                // shape is more legible than its start times.
                ContainerGroup(project: project, containers: members.sorted { a, b in
                    let sa = a.compose?.service ?? "", sb = b.compose?.service ?? ""
                    if sa != sb { return sa.localizedStandardCompare(sb) == .orderedAscending }
                    return (a.compose?.containerNumber ?? 0) < (b.compose?.containerNumber ?? 0)
                })
            }
        if !standalone.isEmpty {
            groups.append(ContainerGroup(project: nil, containers: standalone))
        }
        return groups
    }

    /// Running first, then most recently created.
    private static func displayOrder(_ a: DockerContainer, _ b: DockerContainer) -> Bool {
        if a.isRunning != b.isRunning { return a.isRunning }
        return (a.createdAt ?? .distantPast) > (b.createdAt ?? .distantPast)
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        await refreshAll()
        startVMPollingIfRunning()
        startStatePolling()
    }

    /// Poll for out-of-band changes: VM started/stopped, or clusters created/
    /// deleted via the CLI. On a detected change, refresh just enough to match.
    private func startStatePolling() {
        statePollTask?.cancel()
        statePollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.settings.clusterRefreshInterval else { return }
                try? await Task.sleep(for: interval)
                await self?.pollForExternalChanges()
            }
        }
    }

    private func pollForExternalChanges() async {
        // Don't fight an in-flight action or an active create session — those
        // refresh on their own when they finish.
        guard inFlightAction == nil, creation?.running != true else { return }

        let wasRunning = vm?.isRunning ?? false
        let nowRunning = resolveSingleInstance()?.isRunning ?? false
        if wasRunning != nowRunning {
            await refreshAll()
            startVMPollingIfRunning()
            return
        }
        guard nowRunning else { return }

        // Containers come and go entirely outside marina (a `docker run` in a
        // terminal), so there is no cheaper signal than re-listing them.
        if settings.showContainers { await refreshContainers() }

        // Retry any cluster whose labels/creation-time we never managed to
        // fetch — both are one-shot per cluster (see their doc comments), but
        // that first attempt can race a cluster that only just finished
        // creating (API server/kubeconfig not quite ready yet), and nothing
        // else would ever prompt a second try since the cluster set itself
        // isn't changing. Both no-op immediately once nothing is missing.
        refreshCreationTimes()
        refreshClusterLabels()

        // VM steady; check whether the cluster set changed out from under us.
        guard let latest = try? await MarinaCLI.listClusters() else { return }
        if Set(latest.map(\.name)) != Set(clusters.map(\.name)) {
            await refreshClusters()
            if case .cluster(let name) = selection,
               !clusters.contains(where: { $0.name == name }), creation?.name != name {
                selection = nil
            }
            await refreshSelection()
        }
    }

    func startVMPollingIfRunning() {
        vmPollTask?.cancel()
        vmPollTask = nil
        // Honor the "Show VM stats & graphs" preference — when off we skip the
        // SSH polling entirely (the sidebar rows and charts are hidden too).
        guard settings.showVMStats else { return }
        guard let vm, vm.isRunning, let ssh = vm.ssh else { return }
        let guest = GuestSSH(endpoint: ssh)
        vmPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.collectVMSample(guest: guest)
                guard let interval = self?.settings.vmPollInterval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func collectVMSample(guest: GuestSSH) async {
        guard let raw = await guest.rawSample() else { return }
        guard !Task.isCancelled else { return }
        let prev = lastVMRaw
        lastVMRaw = raw

        var cpuPercent: Double?
        if let prev {
            let totalDelta = Int64(raw.cpuTotalTicks) - Int64(prev.cpuTotalTicks)
            let idleDelta = Int64(raw.cpuIdleTicks) - Int64(prev.cpuIdleTicks)
            if totalDelta > 0 {
                let busy = Double(totalDelta - idleDelta) / Double(totalDelta)
                cpuPercent = max(0, min(100, busy * 100))
            }
        }

        let totalMiB = Double(raw.memTotalKB) / 1024.0
        let usedMiB = Double(raw.memTotalKB - raw.memAvailableKB) / 1024.0
        vmHistory.append(VMSample(
            id: UUID(),
            timestamp: raw.timestamp,
            cpuPercent: cpuPercent,
            memUsedMiB: usedMiB,
            memTotalMiB: totalMiB
        ))

        // Keep the sidebar's Load and Used rows live off the same 5 s sample
        // (they read guestStats, which otherwise only refreshes on refreshAll).
        // uptime/kernel/OS change rarely and stay from the last full stats() call.
        guestStats = GuestSSH.GuestStats(
            uptime: guestStats?.uptime,
            loadAvg: raw.loadAvg ?? guestStats?.loadAvg,
            memTotalKB: raw.memTotalKB,
            memAvailableKB: raw.memAvailableKB,
            kernel: guestStats?.kernel,
            osName: guestStats?.osName,
            rootDisk: guestStats?.rootDisk,
            imageDisk: guestStats?.imageDisk
        )

        await backfillGuestOSInfo(guest: guest)
        await backfillGuestDiskUsage(guest: guest)
    }

    /// Disk usage also only comes from the full `stats()` call, and a failed
    /// one leaves the VM card on the static lima.yaml size with no Images row.
    /// Same retry as `backfillGuestOSInfo`.
    private func backfillGuestDiskUsage(guest: GuestSSH) async {
        guard !fetchingGuestDiskUsage, guestStats?.rootDisk == nil else { return }
        fetchingGuestDiskUsage = true
        defer { fetchingGuestDiskUsage = false }
        guard let disks = await guest.diskUsage() else { return }
        guestStats = GuestSSH.GuestStats(
            uptime: guestStats?.uptime,
            loadAvg: guestStats?.loadAvg,
            memTotalKB: guestStats?.memTotalKB,
            memAvailableKB: guestStats?.memAvailableKB,
            kernel: guestStats?.kernel,
            osName: guestStats?.osName,
            rootDisk: disks.root,
            imageDisk: disks.image
        )
    }

    /// Kernel and distro come from the full `stats()` call, which only runs on
    /// `refreshAll()`. If that one call failed — the ControlMaster socket not
    /// being up yet at launch is the common case — nothing would ever fetch
    /// them again, leaving the About tab on "—". Retry from the poll loop (and
    /// from the About tab itself) until we have them; they never change while
    /// the VM is up, so this settles after one success.
    private func backfillGuestOSInfo(guest: GuestSSH) async {
        guard !fetchingGuestOSInfo,
              guestStats?.kernel == nil || guestStats?.osName == nil
        else { return }
        fetchingGuestOSInfo = true
        defer { fetchingGuestOSInfo = false }
        guard let info = await guest.osInfo() else { return }
        guestStats = GuestSSH.GuestStats(
            uptime: guestStats?.uptime,
            loadAvg: guestStats?.loadAvg,
            memTotalKB: guestStats?.memTotalKB,
            memAvailableKB: guestStats?.memAvailableKB,
            kernel: info.kernel,
            osName: info.osName ?? guestStats?.osName,
            rootDisk: guestStats?.rootDisk,
            imageDisk: guestStats?.imageDisk
        )
    }

    /// Same backfill, for views that need the guest's kernel/distro but can't
    /// rely on the VM poll loop running (it's off when "VM stats" is disabled).
    func ensureGuestOSInfo() async {
        guard let vm, vm.isRunning, let ssh = vm.ssh else { return }
        await backfillGuestOSInfo(guest: GuestSSH(endpoint: ssh))
    }

    /// Reload VM, config, clusters, guest probes; refresh selected-cluster detail if any.
    func refreshAll() async {
        config = InstanceDiscovery.loadConfig()
        vm = resolveSingleInstance()
        // Keep the CLI version current (it changes when the user upgrades marina).
        if let v = try? await MarinaCLI.version() { marinaVersion = v }
        else if marinaVersion == nil { marinaVersion = "marina (unknown)" }
        // Mounts come from the Lima instance config, so this answers even for a
        // stopped VM — which is exactly when someone checks whether an edit landed.
        let status = try? await MarinaCLI.status()
        hostMounts = status?.mounts
        localDNS = status?.dns
        // Host-side file reads (~30 ms); only when marina reports a local CA.
        localCA = status?.dns?.tls != nil ? try? await MarinaCLI.caStatus() : nil
        checkSystemResolver()
        await refreshClusters()
        await refreshCurrentKubeContext()
        if let vm, vm.isRunning, let ssh = vm.ssh {
            let guest = GuestSSH(endpoint: ssh)
            async let ipTask = guest.lima0IP()
            async let statsTask = guest.stats()
            guestLima0IP = await ipTask
            guestStats = await statsTask
            // Only when the feature is on: otherwise this is an SSH round-trip
            // per refresh for a list nothing displays.
            if settings.showContainers { await refreshContainers() }
            // A selected cluster re-reads the records in loadClusterDetail
            // (via refreshSelection below); don't pay for `dns list` twice.
            if case .cluster = selection {} else { await refreshDNSRecords() }
        } else {
            guestLima0IP = nil
            guestStats = nil
            containers = []
            containersError = nil
            dnsRecords = nil
            dnsRecordsError = nil
        }
        // Drop stale selection — but keep it while that cluster is still
        // provisioning (it isn't in `clusters` yet by design).
        if case .cluster(let name) = selection,
           !clusters.contains(where: { $0.name == name }),
           creation?.name != name {
            selection = nil
        }
        if case .mirror(let name) = selection, !mirrors.contains(where: { $0.name == name }) {
            selection = nil
        }
        if case .container(let id) = selection, !containers.contains(where: { $0.id == id }) {
            selection = nil
        }
        await refreshSelection()
    }

    private func resolveSingleInstance() -> Instance? {
        let all = InstanceDiscovery.discoverInstances()
        if let declared = config?.vm.name,
           let match = all.first(where: { $0.name == declared }) {
            return match
        }
        return all.first
    }

    func refreshClusters() async {
        guard vm?.isRunning == true else {
            clusters = []
            clustersError = nil
            clusterCreatedAt = [:]
            clusterLabels = [:]
            clusterNodeVersion = [:]
            return
        }
        clustersLoading = true
        defer { clustersLoading = false }
        do {
            clusters = try await MarinaCLI.listClusters()
            clustersError = nil
        } catch {
            clusters = []
            clustersError = error.localizedDescription
        }
        pruneCreationTimes()
        refreshCreationTimes()
        refreshClusterLabels()
    }

    /// Read kubectl's current-context from the default kubeconfig. Nil when
    /// unset (kubectl exits non-zero) or on any error.
    func refreshCurrentKubeContext() async {
        if let result = try? await ProcessRunner.run("kubectl", ["config", "current-context"]),
           result.ok {
            let ctx = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            currentKubeContext = ctx.isEmpty ? nil : ctx
        } else {
            currentKubeContext = nil
        }
    }

    private func pruneCreationTimes() {
        let names = Set(clusters.map(\.name))
        clusterCreatedAt = clusterCreatedAt.filter { names.contains($0.key) }
        clusterLabels = clusterLabels.filter { names.contains($0.key) }
        clusterNodeVersion = clusterNodeVersion.filter { names.contains($0.key) }
    }

    /// Kubernetes version of the kind nodes, for the sidebar footer.
    ///
    /// Prefers what the nodes actually report (kubelet version); falls back to
    /// the `kind.nodeVersion` image tag from config.yaml when no cluster is up
    /// yet. Clusters created against different image tags are reported as
    /// "mixed", with the per-cluster breakdown in the tooltip.
    var kubeNodeVersionSummary: (text: String, help: String)? {
        let observed = clusters.compactMap { c in clusterNodeVersion[c.name].map { (c.name, $0) } }
        let distinct = Set(observed.map(\.1))
        if distinct.count == 1, let v = distinct.first {
            return (v, "Kubernetes version reported by the kind nodes")
        }
        if distinct.count > 1 {
            let lines = observed.sorted { $0.0 < $1.0 }.map { "\($0.0): \($0.1)" }
            return ("mixed", "Kubernetes versions across clusters\n" + lines.joined(separator: "\n"))
        }
        if let configured = config?.kind?.nodeVersion {
            return (configured, "kindest/node image tag configured in config.yaml — no cluster running")
        }
        return nil
    }

    /// Fetch node labels for any cluster we don't yet have cached. Labels are
    /// effectively static per cluster, so we don't re-query resolved ones.
    private func refreshClusterLabels() {
        let missing = clusters.filter { clusterLabels[$0.name] == nil }
        guard !missing.isEmpty else { return }
        labelsTask?.cancel()
        labelsTask = Task { [weak self] in
            await withTaskGroup(of: (String, KubeNode?).self) { group in
                for c in missing {
                    let kubeconfig = c.kubeconfigPath
                    let name = c.name
                    group.addTask {
                        let nodes = try? await KubeClient(kubeconfigPath: kubeconfig).listNodes()
                        return (name, nodes?.first)
                    }
                }
                for await (name, node) in group {
                    guard !Task.isCancelled, let node else { continue }
                    if let labels = node.metadata.labels { self?.clusterLabels[name] = labels }
                    if let v = node.status.nodeInfo?.kubeletVersion {
                        self?.clusterNodeVersion[name] = v
                    }
                }
            }
        }
    }

    /// Fetch kube-system creation timestamps for any cluster we don't yet
    /// have a cached value for. Creation time never changes, so we never
    /// re-query a cluster we've already resolved.
    private func refreshCreationTimes() {
        let missing = clusters.filter { clusterCreatedAt[$0.name] == nil }
        guard !missing.isEmpty else { return }
        creationTimeTask?.cancel()
        creationTimeTask = Task { [weak self] in
            await withTaskGroup(of: (String, Date?).self) { group in
                for c in missing {
                    let kubeconfig = c.kubeconfigPath
                    let name = c.name
                    group.addTask {
                        let date = await KubeClient(kubeconfigPath: kubeconfig)
                            .kubeSystemCreationTime()
                        return (name, date)
                    }
                }
                for await (name, date) in group {
                    guard !Task.isCancelled, let date else { continue }
                    self?.clusterCreatedAt[name] = date
                }
            }
        }
    }

    // MARK: - Selection

    func refreshSelection() async {
        // Cancel any in-flight metrics polling before changing selection state.
        metricsTask?.cancel()
        metricsTask = nil

        switch selection {
        case .cluster(let name):
            guard let cluster = clusters.first(where: { $0.name == name }) else {
                clusterDetail = nil
                return
            }
            await loadClusterDetail(for: cluster)
            startMetricsPollingIfReady(for: cluster)
        case .mirror, .container, .none:
            clusterDetail = nil
        }
    }

    private func startMetricsPollingIfReady(for cluster: KindCluster) {
        guard clusterDetail?.cluster.name == cluster.name,
              clusterDetail?.metricsServerReady == true
        else { return }
        let client = MetricsClient(kubeconfigPath: cluster.kubeconfigPath)
        let name = cluster.name
        metricsTask?.cancel()
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollMetrics(client: client, clusterName: name)
                guard let interval = self?.settings.metricsPollInterval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func pollMetrics(client: MetricsClient, clusterName: String) async {
        do {
            async let nodesTask = client.fetchNodes()
            async let podsTask = client.fetchPods()
            let nodes = try await nodesTask
            let pods = try await podsTask
            guard !Task.isCancelled else { return }
            let now = Date()
            let sample = ClusterMetricSample(
                timestamp: now,
                totalCPUMillicores: nodes.reduce(0) { $0 + $1.cpuMillicores },
                totalMemoryMiB: nodes.reduce(0) { $0 + $1.memoryMiB },
                perNode: nodes
            )
            var history = metricsHistory[clusterName] ?? MetricsHistory()
            history.append(sample)
            metricsHistory[clusterName] = history
            latestPods[clusterName] = pods

            // Update per-pod history; prune entries whose latest sample is
            // older than the oldest cluster sample we still keep (so pods that
            // disappear roll off in step with the cluster's time window).
            var perPod = podHistory[clusterName] ?? [:]
            for pod in pods {
                var h = perPod[pod.id] ?? PodMetricsHistory()
                h.append(pod)
                perPod[pod.id] = h
            }
            if let earliest = history.samples.first?.timestamp {
                perPod = perPod.filter {
                    ($0.value.samples.last?.timestamp ?? .distantPast) >= earliest
                }
            }
            podHistory[clusterName] = perPod
            metricsError[clusterName] = nil
        } catch {
            metricsError[clusterName] = error.localizedDescription
        }
    }

    /// Compute (and cache) disk usage for a mirror's image cache directory.
    /// The cache lives on the host by default (~/.marina/registry-cache/<name>);
    /// when configured to live in the guest we surface that state without measuring.
    func measureMirrorCache(_ mirror: MarinaConfig.Registries.Mirror) async {
        let storage = config?.registries?.cacheStorage ?? "host"
        if storage == "guest" {
            mirrorCacheSizes[mirror.name] = .storedInGuest
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home
            .appendingPathComponent(".marina")
            .appendingPathComponent("registry-cache")
            .appendingPathComponent(mirror.name)
            .path
        mirrorCacheSizes[mirror.name] = .measuring
        async let sizeTask = DirectorySize.measure(path: path)
        async let countsTask = RegistryCacheInspector.count(path: path)
        let bytes = await sizeTask
        let counts = await countsTask
        if let bytes {
            mirrorCacheSizes[mirror.name] = .measured(
                bytes: bytes,
                tags: counts?.tags,
                repos: counts?.repos,
                path: path
            )
        } else {
            mirrorCacheSizes[mirror.name] = .missing(path: path)
        }
    }

    /// Probe TCP reachability for every (LB IP, TCP port) on the cluster's
    /// LoadBalancer services. Runs in the background; cancels any previous batch.
    func probeLoadBalancers(for cluster: KindCluster) {
        guard let detail = clusterDetail, detail.cluster.name == cluster.name else { return }
        let lbs = detail.services.filter(\.isLoadBalancer)
        var targets: [(ip: String, port: Int)] = []
        for svc in lbs {
            let ips = svc.externalIPs
            let ports = (svc.spec.ports ?? []).filter { $0.protocolValue.uppercased() == "TCP" }
            for ip in ips {
                for port in ports {
                    targets.append((ip, port.port))
                }
            }
        }
        guard !targets.isEmpty else {
            serviceProbes[cluster.name] = [:]
            return
        }

        probeTask?.cancel()
        let name = cluster.name
        probeTask = Task { [weak self] in
            let results = await withTaskGroup(of: (String, ProbeResult).self) { group -> [String: ProbeResult] in
                for target in targets {
                    group.addTask {
                        let ok = await TCPProbe.probe(host: target.ip, port: target.port)
                        return ("\(target.ip):\(target.port)",
                                ProbeResult(timestamp: Date(), isOpen: ok))
                    }
                }
                var bucket: [String: ProbeResult] = [:]
                for await pair in group {
                    bucket[pair.0] = pair.1
                }
                return bucket
            }
            guard !Task.isCancelled else { return }
            self?.serviceProbes[name] = results
        }
    }

    /// Re-read the zone's records. Skipped when marina is too old, the zone is
    /// off, or the VM is down — `marina dns list` would only fail.
    func refreshDNSRecords() async {
        guard localDNS?.enabled == true, vm?.isRunning == true else {
            dnsRecords = nil
            dnsRecordsError = nil
            return
        }
        do {
            dnsRecords = try await MarinaCLI.dnsRecords()
            dnsRecordsError = nil
        } catch {
            dnsRecordsError = error.localizedDescription
        }
    }

    /// Resolve `marina-probe.<domain>` the way apps do, in the background — a
    /// lookup an MDM profile sends to a DoH server can take seconds. When it
    /// fails, `dig @server` tells "the server has no probe record" (an older
    /// marina set DNS up) apart from "the Mac's resolver goes elsewhere".
    func checkSystemResolver() {
        systemResolverTask?.cancel()
        guard let dns = localDNS, dns.enabled, dns.hostResolver, dns.serverRunning == true,
              let domain = dns.domain, let server = dns.server
        else {
            systemResolver = nil
            return
        }
        let name = "\(SystemResolverState.probeLabel).\(domain)"
        systemResolverTask = Task { [weak self] in
            let state: SystemResolverState
            if await HostResolver.resolveIPv4(name).contains(server) {
                state = .ok
            } else {
                let dig = try? await ProcessRunner.run(
                    "/usr/bin/dig", ["@\(server)", "+short", "+time=2", "+tries=1", name, "A"])
                let served = dig?.stdout.split(separator: "\n").contains { $0 == server } ?? false
                state = served ? .bypassed(profile: ManagedDNSProfile.find().first) : .probeMissing
            }
            guard !Task.isCancelled else { return }
            self?.systemResolver = state
        }
    }

    /// Resolve every name in the cluster's subzone through macOS's resolver.
    /// A name that doesn't resolve while its VIP answers points at
    /// `/etc/resolver` (or the DNS container), not at the Service.
    func resolveDNSNames(for cluster: KindCluster) {
        let clusterName = cluster.name
        // The names the Services tab shows — cluster and fleet zone, LoadBalancer
        // VIPs only. Stale headless-Service records aren't worth a lookup.
        let services = clusterDetail?.cluster.name == clusterName ? clusterDetail?.services ?? [] : []
        let names = services.filter(\.isLoadBalancer)
            .flatMap { dnsNames(for: $0, in: clusterName) }
            .map(\.name)
        resolveTask?.cancel()
        guard !names.isEmpty else {
            nameResolutions[clusterName] = [:]
            return
        }
        resolveTask = Task { [weak self] in
            let results = await withTaskGroup(of: (String, NameResolution).self) { group -> [String: NameResolution] in
                for name in Set(names) {
                    group.addTask {
                        let addrs = await HostResolver.resolveIPv4(name)
                        return (name, NameResolution(timestamp: Date(), addresses: addrs))
                    }
                }
                var bucket: [String: NameResolution] = [:]
                for await (name, res) in group { bucket[name] = res }
                return bucket
            }
            guard !Task.isCancelled else { return }
            self?.nameResolutions[clusterName] = results
        }
    }

    /// Publish an existing cluster's Services in the zone. The view confirms
    /// first: attaching restarts the cluster's CoreDNS.
    /// Also what removes the headless-Service records a marina 0.2.0 attach
    /// published, and joins the cluster's ExternalDNS to its fleet zone.
    func attachLocalDNS(to clusterName: String) async {
        guard inFlightAction == nil else { return }
        await runAction("Attaching \(clusterName) to local DNS", scope: .cluster(clusterName)) {
            try await MarinaCLI.dnsAttach(cluster: clusterName)
        }
    }

    /// Issue (or renew) the cluster's wildcard and its fleet's. The view
    /// confirms first: installing the root restarts the nodes' containerd.
    func attachLocalCA(to cluster: KindCluster) async {
        guard inFlightAction == nil else { return }
        await runAction("Issuing TLS wildcard for \(cluster.name)", scope: .cluster(cluster.name)) {
            try await MarinaCLI.caAttach(cluster: cluster.name)
        }
    }

    /// Copy the cluster's (or its fleet's) wildcard Secret into a namespace, so
    /// an Ingress or a pod there can use it.
    func copyWildcardSecret(from cluster: KindCluster, to namespace: String, fleet: Bool) async {
        guard inFlightAction == nil else { return }
        let which = fleet ? "fleet wildcard" : "wildcard"
        await runAction("Copying \(cluster.name)'s \(which) Secret to \(namespace)", scope: .cluster(cluster.name)) {
            try await MarinaCLI.caSecret(cluster: cluster.name, namespace: namespace, fleet: fleet)
        }
    }

    /// The root CA PEM, for a client's trust store. nil on failure.
    func rootCertificatePEM() async -> String? {
        try? await MarinaCLI.caCert()
    }

    /// Called externally when the user toggles metrics-server install/uninstall.
    /// Restart or stop polling based on current readiness.
    func refreshMetricsPolling() {
        if case .cluster(let name) = selection,
           let cluster = clusters.first(where: { $0.name == name }) {
            startMetricsPollingIfReady(for: cluster)
        } else {
            metricsTask?.cancel()
            metricsTask = nil
        }
    }

    func loadClusterDetail(for cluster: KindCluster) async {
        clusterDetail = ClusterDetail(cluster: cluster, loading: true)
        let kube = KubeClient(kubeconfigPath: cluster.kubeconfigPath)
        do {
            async let nodesTask = kube.listNodes()
            async let podsTask = kube.listPods()
            async let servicesTask = kube.listServices()
            async let metricsTask = kube.metricsServerReady()
            async let versionTask = kube.clusterVersion()
            let dnsOn = localDNS?.enabled == true
            async let externalDNSTask: ExternalDNSInfo? = dnsOn ? kube.externalDNS() : nil
            async let recordsTask: Void = refreshDNSRecords()
            let nodes = try await nodesTask
            let pods = try await podsTask
            let services = try await servicesTask
            let metricsReady = await metricsTask
            let version = await versionTask
            let externalDNS = await externalDNSTask
            await recordsTask
            clusterDetail = ClusterDetail(
                cluster: cluster,
                nodes: nodes,
                pods: pods,
                services: services,
                metricsServerReady: metricsReady,
                externalDNS: externalDNS?.state,
                externalDNSIngress: externalDNS?.publishesIngress,
                serverVersion: version,
                loading: false,
                error: nil
            )
            probeLoadBalancers(for: cluster)
            resolveDNSNames(for: cluster)
        } catch {
            clusterDetail = ClusterDetail(
                cluster: cluster,
                loading: false,
                error: error.localizedDescription
            )
        }
    }

    // MARK: - Actions

    func startVM() async {
        await runAction("Starting VM", scope: .vm) { try await MarinaCLI.up() }
    }

    func stopVM() async {
        await runAction("Stopping VM", scope: .vm) { try await MarinaCLI.down() }
    }

    func createCluster(named name: String) async {
        guard inFlightAction == nil, creation?.running != true else { return }
        let label = "Creating cluster \(name)"
        inFlightAction = label
        creation = Creation(name: name)
        // Surface the placeholder and its live log immediately.
        selection = .cluster(name: name)

        // Run the stream in a cancellable task; cancelling it tears down the
        // AsyncStream, which terminates the underlying `marina cluster create`.
        let streamTask = Task { @MainActor in
            for await event in ProcessRunner.stream(
                MarinaCLI.executable, ["cluster", "create", name]
            ) {
                switch event {
                case .output(let text):
                    creation?.log = text
                    if creation?.versionWarning == nil,
                       let warning = Self.detectVersionWarning(in: text) {
                        creation?.versionWarning = warning
                    }
                case .finished(let result):
                    creation?.failed = !result.ok
                    self.appendLog(
                        scope: .cluster(name),
                        label: label,
                        text: self.combinedLog(label: label, result: result)
                    )
                }
            }
        }
        creationTask = streamTask
        await streamTask.value
        let wasCancelled = streamTask.isCancelled
        creationTask = nil

        if wasCancelled {
            creation?.cancelled = true
            creation?.failed = true
            creation?.log += "\n── Cancelled — cleaning up partial cluster ──\n"
            if let del = try? await MarinaCLI.deleteCluster(name: name) {
                creation?.log += combinedLog(label: "Deleting cluster \(name)", result: del)
            }
        }

        creation?.running = false
        inFlightAction = nil
        await refreshAll()
        startVMPollingIfRunning()
        // On success the real cluster is now in the list; drop the session so
        // ClusterDetailView takes over. On failure/cancel keep it so the log stays.
        if creation?.failed == false, clusters.contains(where: { $0.name == name }) {
            creation = nil
        }
    }

    /// Cancel the in-flight cluster creation, if any. The create process is
    /// terminated and the partial cluster is cleaned up (see `createCluster`).
    func cancelCreation() {
        creationTask?.cancel()
    }

    /// Extract marina's mismatch warning line, if present. marina logs (to
    /// stderr) `level=WARN msg="Using a non-default kind node version — …"`
    /// with `requested`/`recommended` fields whenever the configured
    /// nodeVersion differs from the one its bundled kind CLI is validated
    /// against. We surface that verbatim rather than hardcode the default.
    static func detectVersionWarning(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let lower = line.lowercased()
            guard lower.contains("non-default kind node version")
                    || lower.contains("unsupported") && lower.contains("node") else { continue }
            return line.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    func deleteCluster(named name: String) async {
        await runAction("Deleting cluster \(name)", scope: .cluster(name)) {
            try await MarinaCLI.deleteCluster(name: name)
        }
        if case .cluster(let sel) = selection, sel == name {
            selection = nil
        }
    }

    /// Delete every cluster in a fleet via `marina fleet delete`. The view gates
    /// the call behind a confirmation dialog — this is irreversible.
    func deleteFleet(named name: String) async {
        guard inFlightAction == nil else { return }
        await runAction("Deleting fleet \(name)", scope: .fleet(name)) {
            try await MarinaCLI.deleteFleet(name: name)
        }
        if case .cluster(let sel) = selection, !clusters.contains(where: { $0.name == sel }) {
            selection = nil
        }
    }

    /// Delete every cluster, sequentially. Kind clusters share the guest, so
    /// serial deletion avoids racing marina's shared kubeconfig/docker state.
    func deleteAllClusters() async {
        let names = clusters.map(\.name)
        guard !names.isEmpty, inFlightAction == nil else { return }
        inFlightAction = "Deleting all clusters"
        creation = nil
        var log = ""
        for name in names {
            do {
                let result = try await MarinaCLI.deleteCluster(name: name)
                log += combinedLog(label: "Deleting cluster \(name)", result: result)
            } catch {
                log += "Deleting cluster \(name) failed: \(error.localizedDescription)\n"
            }
        }
        appendLog(scope: .general, label: "Deleting all clusters", text: log)
        inFlightAction = nil
        selection = nil
        await refreshAll()
        startVMPollingIfRunning()
    }

    /// Add (or overwrite) a node label on every node of a cluster, then refresh
    /// its cached labels and reloaded detail so the new label shows immediately.
    func addLabel(to cluster: KindCluster, key: String, value: String) async {
        clusterLabels[cluster.name] = nil  // invalidate so refreshAll refetches
        await runAction("Label \(cluster.name): \(key)=\(value)", scope: .cluster(cluster.name)) {
            try await MarinaCLI.labelCluster(name: cluster.name, key: key, value: value)
        }
    }

    /// Set kubectl's current-context (in the default kubeconfig) to this
    /// cluster. marina merges each cluster into ~/.kube/config under a context
    /// named after the cluster, so `use-context <name>` targets it directly.
    func useContext(for cluster: KindCluster) async {
        await runAction("Switching kubectl context to \(cluster.name)", scope: .cluster(cluster.name)) {
            try await ProcessRunner.run("kubectl", ["config", "use-context", cluster.name])
        }
    }

    func installMetricsServer(for cluster: KindCluster) async {
        await runAction("Installing metrics-server on \(cluster.name)", scope: .metrics(cluster.name)) {
            try await Helm(kubeconfigPath: cluster.kubeconfigPath).installMetricsServer()
        }
    }

    func uninstallMetricsServer(for cluster: KindCluster) async {
        await runAction("Uninstalling metrics-server on \(cluster.name)", scope: .metrics(cluster.name)) {
            try await Helm(kubeconfigPath: cluster.kubeconfigPath).uninstallMetricsServer()
        }
    }

    // MARK: - Diagnostics

    /// Run `marina doctor`, optionally letting it apply the repairs it can make
    /// itself. On-demand only (from the Settings window's Diagnostics tab).
    func runDoctor(applyFixes: Bool = false) async {
        guard !doctorRunning else { return }
        doctorRunning = true
        defer { doctorRunning = false }
        do {
            doctorReport = try await MarinaCLI.doctor(fix: applyFixes)
            doctorError = nil
        } catch {
            doctorReport = nil
            doctorError = error.localizedDescription
        }
        doctorRanAt = Date()
        if applyFixes {
            // A successful route/iptables/forwarding repair changes what the
            // rest of the UI can reach, so re-read everything.
            await refreshAll()
        }
    }

    // MARK: - Guest containers

    /// Guest-side docker client, or nil when the VM isn't up.
    private var docker: DockerClient? {
        guard let vm, vm.isRunning, let ssh = vm.ssh else { return nil }
        return DockerClient(guest: GuestSSH(endpoint: ssh))
    }

    /// Re-list the guest's containers. One SSH round-trip; safe to call from
    /// the state poll loop.
    func refreshContainers() async {
        guard let docker else {
            containers = []
            containersError = nil
            return
        }
        containersLoading = true
        defer { containersLoading = false }
        do {
            containers = try await docker.list()
            containersError = nil
        } catch {
            containers = []
            containersError = error.localizedDescription
        }
    }

    /// Fetch (and cache) the tail of a container's log.
    func loadContainerLogs(_ container: DockerContainer, lines: Int = 200) async {
        guard let docker else { return }
        do {
            let text = try await docker.logs(id: container.id, lines: lines)
            containerLogs[container.id] = text.isEmpty ? "(no output)" : text
        } catch {
            containerLogs[container.id] = "Failed to read logs: \(error.localizedDescription)"
        }
    }

    enum ContainerAction: String, Sendable {
        case start, stop, restart

        var verb: String {
            switch self {
            case .start: return "Starting"
            case .stop: return "Stopping"
            case .restart: return "Restarting"
            }
        }
    }

    /// Start/stop/restart a container in the guest. Deliberately no `docker rm`:
    /// removal is unrecoverable and these containers aren't marina's to destroy.
    func performContainerAction(_ action: ContainerAction, on container: DockerContainer) async {
        guard let docker, inFlightAction == nil else { return }
        let label = "\(action.verb) container \(container.name)"
        inFlightAction = label
        defer { inFlightAction = nil }
        let text: String
        do {
            let out: String
            switch action {
            case .start: out = try await docker.start(id: container.id)
            case .stop: out = try await docker.stop(id: container.id)
            case .restart: out = try await docker.restart(id: container.id)
            }
            text = "\(label) — ok\n\(out)"
        } catch {
            text = "\(label) failed: \(error.localizedDescription)"
        }
        appendLog(scope: .container(container.id), label: label, text: text)
        await refreshContainers()
    }

    /// Start/stop every container in a compose stack as one docker call.
    ///
    /// Not `docker compose up`/`down`: this project has already lost a
    /// running kind node to compose's orphan sweep on `up` (see CLAUDE.md), so
    /// the real compose CLI stays off-limits here. `docker start`/`stop`
    /// against the stack's own container ids gets the same practical result
    /// — the stack's containers come up or go down — without touching
    /// anything else in the guest.
    func performStackAction(_ action: ContainerAction, on group: ContainerGroup) async {
        guard let docker, inFlightAction == nil, !group.isStandalone else { return }
        guard action == .start || action == .stop else { return }
        let ids = group.containers.map(\.id)
        let label = "\(action.verb) stack \(group.title)"
        inFlightAction = label
        defer { inFlightAction = nil }
        let text: String
        do {
            let out = action == .start
                ? try await docker.start(ids: ids)
                : try await docker.stop(ids: ids)
            text = "\(label) — ok\n\(out)"
        } catch {
            text = "\(label) failed: \(error.localizedDescription)"
        }
        appendLog(scope: .composeStack(group.title), label: label, text: text)
        await refreshContainers()
    }

    /// Force-remove every container in a compose stack. Not `docker compose
    /// down` — that walks into the same orphan-sweep failure mode as `up` (see
    /// CLAUDE.md) — but plain `docker rm -f` against the stack's own ids.
    ///
    /// This exists because `docker compose ls` hides a fully stopped project
    /// by default (it lists running projects only; `-a` shows the rest), so a
    /// stack sitting `exited` in the guest is invisible to a plain `ls` even
    /// though `compose down` would work fine on it. The app has no such blind
    /// spot — it always lists every container — so this is the in-app way to
    /// clear one out. The view gates the call behind a confirmation dialog —
    /// this is irreversible.
    func performStackRemoval(_ group: ContainerGroup) async {
        guard let docker, inFlightAction == nil, !group.isStandalone else { return }
        let ids = group.containers.map(\.id)
        let label = "Removing stack \(group.title)"
        inFlightAction = label
        defer { inFlightAction = nil }
        let text: String
        do {
            let out = try await docker.remove(ids: ids)
            text = "\(label) — ok\n\(out)"
        } catch {
            text = "\(label) failed: \(error.localizedDescription)"
        }
        appendLog(scope: .composeStack(group.title), label: label, text: text)
        await refreshContainers()
    }

    private func runAction(_ label: String, scope: LogScope, _ work: () async throws -> ProcessResult) async {
        inFlightAction = label
        creation = nil  // a new action supersedes any finished create session
        defer { inFlightAction = nil }
        let text: String
        do {
            let result = try await work()
            text = combinedLog(label: label, result: result)
        } catch {
            text = "\(label) failed: \(error.localizedDescription)"
        }
        appendLog(scope: scope, label: label, text: text)
        await refreshAll()
        startVMPollingIfRunning()
    }

    private func combinedLog(label: String, result: ProcessResult) -> String {
        var out = "\(label) — exit \(result.exitCode)\n"
        if !result.stdout.isEmpty { out += "── stdout ──\n\(result.stdout)\n" }
        if !result.stderr.isEmpty { out += "── stderr ──\n\(result.stderr)\n" }
        return out
    }
}
