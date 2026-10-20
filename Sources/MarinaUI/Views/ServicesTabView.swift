import SwiftUI

struct ServicesTabView: View {
    @Bindable var model: AppModel
    let cluster: KindCluster
    let services: [KubeService]
    let bridgeCIDR: String?

    private var loadBalancers: [KubeService] {
        services.filter { $0.isLoadBalancer }
    }

    private var probes: [String: AppModel.ProbeResult] {
        model.serviceProbes[cluster.name] ?? [:]
    }

    var body: some View {
        if loadBalancers.isEmpty {
            ContentUnavailableView {
                Label("No LoadBalancer services", systemImage: "network")
            } description: {
                Text("Expose a workload with `type: LoadBalancer` and MetalLB will assign it an IP from the kind bridge CIDR.")
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                header
                if model.dnsZone(for: cluster.name) != nil,
                   let state = model.systemResolver, state != .ok,
                   let domain = model.localDNS?.domain {
                    SystemResolverBanner(state: state, domain: domain)
                }
                ForEach(loadBalancers) { svc in
                    ServiceCard(
                        service: svc,
                        probes: probes,
                        dns: dnsContext(for: svc),
                        routable: { model.isRoutable($0) }
                    )
                }
            }
        }
    }

    /// nil when the zone is off or marina predates it — the card then renders
    /// with IP endpoints only.
    private func dnsContext(for svc: KubeService) -> ServiceDNS? {
        guard let zone = model.dnsZone(for: cluster.name) else { return nil }
        let names = model.dnsNames(for: svc, in: cluster.name)
        return ServiceDNS(
            zone: zone,
            server: model.localDNS?.server,
            names: names,
            sources: Dictionary(uniqueKeysWithValues: names.map {
                ($0.name, model.dnsNameSource($0.name, for: svc, in: cluster.name))
            }),
            fleetNames: Set(names.map(\.name).filter { model.isFleetName($0, in: cluster.name) }),
            coverage: Dictionary(uniqueKeysWithValues: names.compactMap { rec in
                model.wildcardCoverage(for: rec.name, in: cluster.name).map { (rec.name, $0) }
            }),
            caEnabled: model.localCA?.enabled == true,
            resolutions: model.nameResolutions[cluster.name] ?? [:],
            externalDNS: model.clusterDetail?.cluster.name == cluster.name
                ? model.clusterDetail?.externalDNS : nil,
            publishesIngress: (model.clusterDetail?.cluster.name == cluster.name
                ? model.clusterDetail?.externalDNSIngress : nil) ?? model.dnsIngressEnabled,
            resolverBypassed: model.systemResolver.map { if case .bypassed = $0 { return true }; return false } ?? false
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("LoadBalancer services")
                .font(.headline)
            Text("\(loadBalancers.count) total")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let cidr = bridgeCIDR {
                Text("kind bridge \(cidr)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// What the local DNS zone knows about one Service.
private struct ServiceDNS {
    let zone: String
    let server: String?
    /// Annotated names first, then other names on the VIP, automatic last.
    let names: [LocalDNSRecord]
    let sources: [String: DNSNameSource]
    /// Names under the fleet zone rather than the cluster's.
    let fleetNames: Set<String>
    /// Names a marina wildcard covers.
    let coverage: [String: WildcardCoverage]
    /// Whether the local CA is on — decides whether "no wildcard" is worth saying.
    let caEnabled: Bool
    let resolutions: [String: NameResolution]
    let externalDNS: ExternalDNSState?
    /// Whether the cluster's ExternalDNS runs `--source=ingress` — the deployed
    /// args when read, else `network.dns.ingress`.
    let publishesIngress: Bool
    /// macOS sends the zone's lookups past /etc/resolver: every red dot has
    /// that one cause, already explained in the banner.
    let resolverBypassed: Bool

    /// The name endpoints use for a VIP: the most deliberate one on it.
    func host(for ip: String) -> String? {
        names.first { $0.ip == ip }?.name
    }
}

private struct ServiceCard: View {
    let service: KubeService
    let probes: [String: AppModel.ProbeResult]
    let dns: ServiceDNS?
    let routable: (String) -> Bool?

    private var ips: [String] { service.externalIPs }
    private var ports: [KubeService.Port] { service.spec.ports ?? [] }
    private var unroutedIPs: [String] { ips.filter { routable($0) == false } }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                titleRow

                if ips.isEmpty {
                    Text("Pending external IP…")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !unroutedIPs.isEmpty {
                    Label("\(unroutedIPs.joined(separator: ", ")) is outside the kind bridge CIDR — the Mac has no route to it",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let dns, !ips.isEmpty {
                    namesBlock(dns)
                }

                if !ports.isEmpty {
                    Divider()
                    portsGrid
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(service.metadata.name).font(.headline)
            Text(service.metadata.namespace ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            Spacer()
            ForEach(ips, id: \.self) { ip in
                Text(verbatim: ip)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .help("LoadBalancer VIP")
            }
        }
    }

    @ViewBuilder
    private func namesBlock(_ dns: ServiceDNS) -> some View {
        if dns.names.isEmpty {
            Label(emptyNamesText(dns), systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(dns.names.enumerated()), id: \.element.id) { index, rec in
                    DNSNameRow(
                        record: rec,
                        source: dns.sources[rec.name] ?? .sharedVIP,
                        isPrimary: index == 0,
                        showIP: ips.count > 1,
                        resolution: dns.resolutions[rec.name],
                        server: dns.server,
                        isFleet: dns.fleetNames.contains(rec.name),
                        coverage: dns.coverage[rec.name],
                        caEnabled: dns.caEnabled,
                        publishesIngress: dns.publishesIngress,
                        resolverBypassed: dns.resolverBypassed
                    )
                }
            }
        }
    }

    private func emptyNamesText(_ dns: ServiceDNS) -> String {
        switch dns.externalDNS {
        case .missing:
            return "No DNS name: this cluster isn't attached to local DNS. Attach it from the Info tab."
        case .notReady:
            return "No DNS name yet: ExternalDNS isn't ready in this cluster."
        default:
            return "No DNS name yet. ExternalDNS publishes new Services within ~15 s — press ⌘R to re-check."
        }
    }

    /// One row per port (per VIP when there are several). The endpoint column
    /// links only when the port says it speaks HTTP(S) — a raw TCP port gets
    /// `host:port` to copy, not a URL a browser can't use.
    private var portsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Color.clear.frame(width: 8, height: 1)
                columnHeader("Port")
                columnHeader("Protocol")
                columnHeader("App protocol")
                columnHeader("Name")
                columnHeader("Target")
                columnHeader("Endpoint")
                Color.clear.frame(width: 1, height: 1)
            }
            ForEach(endpointIPs, id: \.self) { ip in
                ForEach(ports) { port in
                    PortRow(
                        port: port,
                        ip: ip,
                        host: dns?.host(for: ip),
                        probe: ip.isEmpty ? nil : probes["\(ip):\(port.port)"]
                    )
                }
            }
        }
    }

    /// Ports are worth describing before MetalLB assigns a VIP; "" stands for
    /// "no address yet".
    private var endpointIPs: [String] { ips.isEmpty ? [""] : ips }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

/// One published name, with whether macOS resolves it to the VIP.
private struct DNSNameRow: View {
    let record: LocalDNSRecord
    let source: DNSNameSource
    /// The name the port endpoints use.
    let isPrimary: Bool
    /// Only worth repeating when the Service has several VIPs.
    let showIP: Bool
    let resolution: NameResolution?
    let server: String?
    let isFleet: Bool
    let coverage: WildcardCoverage?
    let caEnabled: Bool
    let publishesIngress: Bool
    let resolverBypassed: Bool
    @State private var copied: String?

    private var digCommand: String {
        server.map { "dig @\($0) \(record.name) +short" } ?? "dscacheutil -q host -a name \(record.name)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            resolutionDot.frame(width: 12)
            Text(verbatim: record.name)
                .font(.system(.callout, design: .monospaced).weight(isPrimary ? .semibold : .regular))
                .foregroundStyle(isPrimary ? .primary : .secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            if showIP {
                Text(verbatim: "→ \(record.ip)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(sourceLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                .help(sourceHelp)
            if isFleet {
                Text("fleet")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
                    .help("Fleet-wide name: published under the fleet zone by this cluster's ExternalDNS. The first member to publish a name owns it.")
            }
            if let coverage {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .help("Covered by the marina wildcard \(coverage.wildcard) (Secret \(coverage.secret)), trusted by this Mac through the marina root CA.")
            } else if caEnabled {
                Image(systemName: "lock.slash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help(Self.noWildcardHelp)
            }
            Spacer()
            copyButton(record.name, systemImage: "doc.on.doc", help: "Copy \(record.name)")
            copyButton(digCommand, systemImage: "terminal",
                       help: "Copy `\(digCommand)`. dig skips /etc/resolver, so a bare `dig \(record.name)` fails even when browsers and curl resolve it; use `dscacheutil -q host -a name \(record.name)` to test the Mac's own path.")
        }
    }

    private var sourceLabel: String {
        switch source {
        case .annotation: return "annotation"
        case .automatic: return "automatic"
        case .sharedVIP: return "same VIP"
        }
    }

    private var sourceHelp: String {
        switch source {
        case .annotation:
            return "From the Service's external-dns.kubernetes.io/hostname annotation."
        case .automatic:
            return "The name marina gives every LoadBalancer Service (network.dns.nameTemplate). Still published when the Service sets its own hostname."
        case .sharedVIP:
            return publishesIngress
                ? "Published by another object on the same VIP — typically an Ingress host served by this controller."
                : "Published by another object on the same VIP: another Service sharing it, or an Ingress host left over from before network.dns.ingress went off (re-attach the cluster from the Info tab to remove those)."
        }
    }

    static let noWildcardHelp = "No marina wildcard covers this name. A wildcard covers one label, so <svc>.<ns>.<cluster>.<domain> isn't covered: use a one-label hostname annotation (app.<cluster>.<domain>), a cert-manager Certificate from the marina-ca ClusterIssuer, or issue the cluster's wildcard from the Info tab."

    private func copyButton(_ text: String, systemImage: String, help: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = text
            Task {
                try? await Task.sleep(for: .seconds(2))
                if copied == text { copied = nil }
            }
        } label: {
            Image(systemName: copied == text ? "checkmark" : systemImage)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    @ViewBuilder
    private var resolutionDot: some View {
        if let resolution {
            let (color, text) = verdict(resolution)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .help(text)
        } else {
            ProgressView()
                .controlSize(.mini)
                .help("Resolving…")
        }
    }

    private func verdict(_ r: NameResolution) -> (Color, String) {
        if r.addresses.contains(record.ip) {
            return (.green, "Resolves on this Mac to \(record.ip)")
        }
        if r.addresses.isEmpty, resolverBypassed {
            return (.red, "Does not resolve on this Mac: macOS sends the zone's lookups past /etc/resolver — see the warning above the services.")
        }
        if r.addresses.isEmpty {
            return (.red, "Does not resolve on this Mac. marina publishes it, so check /etc/resolver and the DNS server under Settings › Diagnostics. macOS caches a failed lookup for ~75 s, so a name queried before it was published can take that long to appear.")
        }
        return (.orange, "Resolves to \(r.addresses.joined(separator: ", ")), not \(record.ip) — a stale cached answer, or another resolver claims the domain")
    }
}

/// One Service port as a grid row: what the port is, then where to reach it.
private struct PortRow: View {
    let port: KubeService.Port
    /// "" before MetalLB assigns a VIP.
    let ip: String
    /// Published DNS name for this VIP, used in the endpoint when present.
    let host: String?
    let probe: AppModel.ProbeResult?
    @State private var copied = false

    private var isTCP: Bool { port.protocolValue.uppercased() == "TCP" }
    private var address: String { host ?? ip }
    private var endpoint: String { "\(address):\(port.port)" }
    private var scheme: PortScheme? { PortScheme.infer(port) }

    private var url: URL? {
        guard let scheme, !ip.isEmpty else { return nil }
        let defaultPort = (scheme.name == "http" && port.port == 80) || (scheme.name == "https" && port.port == 443)
        return URL(string: "\(scheme.name)://\(address)\(defaultPort ? "" : ":\(port.port)")")
    }

    var body: some View {
        GridRow(alignment: .center) {
            probeDot
            Text(verbatim: String(port.port))
                .font(.system(.callout, design: .monospaced).weight(.medium))
            Text(port.protocolValue.uppercased())
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            optional(port.appProtocol)
            optional(port.name)
            optional(port.targetPortString.flatMap { $0 == String(port.port) ? nil : $0 })
                .help("targetPort — the container port traffic is forwarded to")
            endpointCell
                .gridColumnAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            copyButton
        }
    }

    @ViewBuilder
    private var endpointCell: some View {
        if ip.isEmpty {
            Text("—").foregroundStyle(.tertiary)
        } else if let url, let scheme {
            Link(url.absoluteString, destination: url)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help("\(scheme.name.uppercased()) — \(scheme.reason)")
        } else {
            Text(verbatim: endpoint)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(isTCP
                      ? "Raw TCP: nothing on the port says it speaks HTTP. Set appProtocol: http or https (or name the port http-… / https-…) to get a link."
                      : "\(port.protocolValue) port")
        }
    }

    private func optional(_ value: String?) -> some View {
        Text(verbatim: value ?? "—")
            .font(.callout.monospaced())
            .foregroundStyle(value == nil ? .tertiary : .secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var copyButton: some View {
        if ip.isEmpty {
            Color.clear.frame(width: 1, height: 1)
        } else {
            let text = url?.absoluteString ?? endpoint
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy \(text)")
        }
    }

    @ViewBuilder
    private var probeDot: some View {
        if ip.isEmpty {
            Color.clear.frame(width: 8, height: 8)
        } else if !isTCP {
            Image(systemName: "minus.circle")
                .foregroundStyle(.tertiary)
                .font(.caption)
                .help("TCP probe not applicable for \(port.protocolValue) port")
        } else if let probe {
            Circle()
                .fill(probe.isOpen ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .help(probeTooltip(probe))
        } else {
            ProgressView()
                .controlSize(.mini)
                .help("Probing…")
        }
    }

    private func probeTooltip(_ p: AppModel.ProbeResult) -> String {
        let ago = Self.relativeFormatter.localizedString(for: p.timestamp, relativeTo: Date())
        return p.isOpen
            ? "TCP connect to \(ip):\(port.port) succeeded (\(ago))"
            : "TCP connect to \(ip):\(port.port) failed (\(ago))"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

/// The URL scheme a Service port speaks, when something on the port says so.
/// Order of trust: `appProtocol` (explicit, so a non-HTTP value means no
/// link), then the port name's protocol prefix (`http`, `https-admin` — the
/// Istio convention), then the well-known port numbers.
struct PortScheme: Equatable {
    let name: String
    let reason: String

    static func infer(_ port: KubeService.Port) -> PortScheme? {
        guard port.protocolValue.uppercased() == "TCP" else { return nil }
        if let app = port.appProtocol?.lowercased() {
            switch app {
            case "http", "http2", "h2c", "kubernetes.io/h2c":
                return PortScheme(name: "http", reason: "from appProtocol \(app)")
            case "https":
                return PortScheme(name: "https", reason: "from appProtocol \(app)")
            default:
                return nil
            }
        }
        if let name = port.name?.lowercased() {
            let prefix = name.split(separator: "-").first.map(String.init) ?? name
            switch prefix {
            case "http", "http2", "h2c":
                return PortScheme(name: "http", reason: "from the port name \(name)")
            case "https":
                return PortScheme(name: "https", reason: "from the port name \(name)")
            default:
                break
            }
        }
        switch port.port {
        case 80, 8080:
            return PortScheme(name: "http", reason: "guessed from port \(port.port)")
        case 443, 8443:
            return PortScheme(name: "https", reason: "guessed from port \(port.port)")
        default:
            return nil
        }
    }
}
