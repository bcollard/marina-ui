import SwiftUI
import AppKit

/// Settings › Diagnostics. Two independent questions: is the marina stack
/// healthy (`marina doctor`), and is this copy of the app the one the developer
/// shipped (codesign + Gatekeeper).
struct DiagnosticsTabView: View {
    @Bindable var model: AppModel
    @State private var signature = CodeSignatureModel()
    @State private var copiedRootCA = false

    var body: some View {
        Form {
            doctorSection
            environmentSection
            if let dns = model.localDNS {
                localDNSSection(dns)
            }
            integritySection
        }
        .formStyle(.grouped)
        .task {
            // Both checks are cheap and answer the question the user opened
            // this tab to ask, so run them on appear rather than making them
            // click twice. Re-runs are manual.
            if model.doctorReport == nil, !model.doctorRunning {
                await model.runDoctor()
            }
            if signature.status == nil {
                await signature.check()
            }
            if model.dnsRecords == nil {
                await model.refreshDNSRecords()
            }
        }
    }

    // MARK: - marina doctor

    @ViewBuilder
    private var doctorSection: some View {
        Section {
            if let report = model.doctorReport {
                ForEach(report.checks) { check in
                    DoctorCheckRow(check: check)
                }
            } else if let error = model.doctorError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if !model.doctorRunning {
                Text("Not run yet.").foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Run diagnostics") {
                    Task { await model.runDoctor() }
                }
                .controlSize(.small)
                .disabled(model.doctorRunning)

                if let report = model.doctorReport, !report.fixableFailures.isEmpty {
                    Button("Apply \(report.fixableFailures.count) fix\(report.fixableFailures.count == 1 ? "" : "es")") {
                        Task { await model.runDoctor(applyFixes: true) }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .help("Runs marina doctor --fix. The macOS route repair, the /etc/resolver file for local DNS and trusting the local CA need sudo, which an app bundle can't prompt for — if either fails, run the command shown under it in a terminal.")
                }

                if model.doctorRunning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if let ranAt = model.doctorRanAt, !model.doctorRunning {
                    Text(ranAt, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text("Health checks")
                if let report = model.doctorReport {
                    summaryBadge(report)
                }
            }
        } footer: {
            Text("""
                 Runs `marina doctor`: the Lima hostagent, the VM, the macOS \
                 route to the kind bridge, Rosetta on both sides, the guest's \
                 no-NAT exemption, IP forwarding, the local DNS path from the \
                 Mac and the local CA's trust. Nothing here is polled — \
                 the probes are too heavy for a background loop.
                 """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summaryBadge(_ report: DoctorReport) -> some View {
        let (text, tint): (String, Color) = {
            if report.failureCount > 0 {
                return ("\(report.failureCount) failing", .red)
            }
            if report.warningCount > 0 {
                return ("\(report.warningCount) warning\(report.warningCount == 1 ? "" : "s")", .orange)
            }
            return ("all \(report.checks.count) passing", .green)
        }()
        return Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
    }

    // MARK: - Proxy and CA trust

    /// The two settings that decide whether pulls work at all on a corporate
    /// network, read from the marina config. Both are invisible everywhere else
    /// in the UI and both produce failures that look like something other than
    /// what they are — a proxy-less pull hangs, an untrusted CA fails with
    /// "certificate signed by unknown authority".
    @ViewBuilder
    private var environmentSection: some View {
        Section {
            LabeledContent("HTTP proxy") {
                Text(proxyDescription)
                    .font(.callout)
                    .foregroundStyle(model.config?.network?.proxy?.isExplicit == true
                                     ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .multilineTextAlignment(.trailing)
            }
            if let noProxy = model.config?.network?.proxy?.noProxy, !noProxy.isEmpty {
                LabeledContent("Proxy exemptions") {
                    Text(noProxy.joined(separator: ", "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            LabeledContent("Extra CA trust") {
                Text(caCertsDescription)
                    .font(.callout)
                    .foregroundStyle(caCertFiles.isEmpty
                                     ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .multilineTextAlignment(.trailing)
            }
            ForEach(caCertFiles, id: \.self) { file in
                Text(file)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } header: {
            Text("Network & trust")
        } footer: {
                Text("From your marina config. marina applies both to dockerd, the registry mirrors and every kind node — and computes the no-proxy list (bridge CIDR, cluster subnets, mirror names) itself, so cluster-internal traffic never goes to the proxy. An unset proxy still means macOS's own settings are inherited.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var proxyDescription: String {
        guard let proxy = model.config?.network?.proxy else {
            return "inherited from macOS"
        }
        if proxy.isExplicit {
            let http = proxy.http ?? ""
            let https = proxy.https ?? ""
            if !http.isEmpty, !https.isEmpty, http != https { return "\(http) / \(https)" }
            return http.isEmpty ? https : http
        }
        return proxy.inheritsFromHost ? "inherited from macOS" : "none"
    }

    private var caCertFiles: [String] {
        model.config?.vm.caCerts?.files ?? []
    }

    private var caCertsDescription: String {
        let n = caCertFiles.count
        if n == 0 { return "system roots only" }
        return "\(n) extra CA\(n == 1 ? "" : "s")"
    }

    // MARK: - Local DNS

    /// The zone's moving parts, from `marina status` (and `marina dns list`
    /// for the records). marina doctor's "Local DNS" check probes the real
    /// host path; this shows which piece is which.
    @ViewBuilder
    private func localDNSSection(_ dns: MarinaStatus.DNS) -> some View {
        Section {
            if !dns.enabled {
                LabeledContent("Local DNS") {
                    Text("off (network.dns.enabled: false)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Zone") {
                    Text(verbatim: "*.\(dns.domain ?? "—")")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("DNS server") {
                    HStack(spacing: 6) {
                        Text(dns.server ?? "—")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        dnsStateBadge(dns.serverRunning.map { $0 ? .ok("running") : .bad("not running") }
                                      ?? .unknown("VM stopped"))
                    }
                }
                LabeledContent("macOS resolver") {
                    HStack(spacing: 6) {
                        Text(verbatim: "/etc/resolver/\(dns.domain ?? "")")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        dnsStateBadge(dns.hostResolver ? .ok("present") : .bad("missing"))
                    }
                }
                if !dns.hostResolver {
                    Text("Without it only the VM and the pods resolve the zone. Run `marina up` in a terminal: writing the file needs sudo once, which the app can't prompt for.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let state = model.systemResolver {
                    LabeledContent("Apps on this Mac") {
                        HStack(spacing: 6) {
                            Text(verbatim: "\(SystemResolverState.probeLabel).\(dns.domain ?? "")")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            dnsStateBadge(resolverPart(state))
                        }
                    }
                    .help("Resolved with getaddrinfo, the path curl and browsers take. The DNS server row above answers dig; this row is what apps actually see.")
                    if state != .ok, let domain = dns.domain {
                        SystemResolverBanner(state: state, domain: domain)
                    }
                }
                LabeledContent("Published names") {
                    if let records = model.dnsRecords {
                        Text("\(records.count)")
                            .font(.callout.monospacedDigit())
                    } else if let err = model.dnsRecordsError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                let unrouted = model.unroutedDNSRecords
                if !unrouted.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("\(unrouted.count) name\(unrouted.count == 1 ? "" : "s") point outside the kind bridge (\(model.config?.network?.kindBridgeCIDR ?? "?")). They resolve, but the Mac has no route to the address.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        let stale = model.clustersWithUnroutedRecords
                        if !stale.isEmpty {
                            Text("An ExternalDNS installed by marina 0.2.0 published every Service type, headless ones with pod IPs. Re-attaching limits it to LoadBalancer Services and removes these.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                ForEach(stale, id: \.self) { name in
                                    Button("Re-attach \(name)") {
                                        Task { await model.attachLocalDNS(to: name) }
                                    }
                                    .controlSize(.small)
                                    .disabled(model.inFlightAction != nil)
                                    .help("marina dns attach \(name) — restarts the cluster's CoreDNS, briefly interrupting in-cluster DNS")
                                }
                                if let action = model.inFlightAction, action.contains("local DNS") {
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                        ForEach(unrouted) { rec in
                            Text(verbatim: "\(rec.name) → \(rec.ip)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            if let tls = dns.tls, dns.enabled {
                localCARows(tls)
            }
        } header: {
            Text("Local DNS")
        } footer: {
            Text("Every LoadBalancer Service resolves as <service>.<namespace>.<cluster>.\(dns.domain ?? "<domain>") from the Mac, the VM and pods. `dig` skips /etc/resolver: query the server directly (`dig @\(dns.server ?? "<server>") <name>`) or test the Mac's own path with `dscacheutil -q host -a name <name>`.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The local CA: whether the root exists and macOS trusts it, and which
    /// clusters/fleets hold a wildcard.
    @ViewBuilder
    private func localCARows(_ tls: MarinaStatus.DNS.TLS) -> some View {
        LabeledContent("Local CA") {
            HStack(spacing: 6) {
                if let notAfter = model.localCA?.notAfter {
                    Text("root expires \(notAfter)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                dnsStateBadge(!tls.exists ? .bad("no root")
                              : tls.trusted ? .ok("trusted") : .bad("not trusted"))
            }
        }
        if !tls.exists {
            Text("marina creates the root on the next `marina up`.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if !tls.trusted {
            Text("Browsers and curl reject every certificate under the zone until macOS trusts the root. Run `marina ca trust` in a terminal: it writes to the System keychain with sudo, which the app can't prompt for.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let ca = model.localCA {
            LabeledContent("Wildcards") {
                Text(wildcardSummary(ca))
                    .font(.callout)
                    .foregroundStyle(ca.clusters.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .multilineTextAlignment(.trailing)
            }
            let missing = model.clusters.map(\.name).filter { ca.cluster($0) == nil }
            if !missing.isEmpty {
                Text("No wildcard yet: \(missing.joined(separator: ", ")). Issue one from the cluster's Info tab (marina ca attach).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if tls.exists, let root = tls.root {
            HStack(spacing: 8) {
                Text(root)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    Task {
                        guard let pem = await model.rootCertificatePEM() else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pem, forType: .string)
                        copiedRootCA = true
                        try? await Task.sleep(for: .seconds(2))
                        copiedRootCA = false
                    }
                } label: {
                    Label(copiedRootCA ? "Copied" : "Copy root PEM",
                          systemImage: copiedRootCA ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
                .help("marina ca cert — for a client that doesn't read the macOS keychain (Node, Python, Firefox, a container)")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root)])
                } label: {
                    Image(systemName: "folder")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
    }

    private func wildcardSummary(_ ca: LocalCAStatus) -> String {
        let c = ca.clusters.count, f = ca.fleets?.count ?? 0
        if c == 0, f == 0 { return "none issued" }
        var parts = ["\(c) cluster\(c == 1 ? "" : "s")"]
        if f > 0 { parts.append("\(f) fleet\(f == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    private func resolverPart(_ state: SystemResolverState) -> DNSPartState {
        switch state {
        case .ok: return .ok("resolves")
        case .probeMissing: return .unknown("untested")
        case .bypassed: return .bad("bypassed")
        }
    }

    private enum DNSPartState {
        case ok(String), bad(String), unknown(String)
    }

    private func dnsStateBadge(_ state: DNSPartState) -> some View {
        let (text, tint): (String, Color) = {
            switch state {
            case .ok(let t): return (t, .green)
            case .bad(let t): return (t, .red)
            case .unknown(let t): return (t, .secondary)
            }
        }()
        return Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.18)))
            .foregroundStyle(tint)
    }

    // MARK: - App integrity

    @ViewBuilder
    private var integritySection: some View {
        Section {
            if let status = signature.status {
                LabeledContent("Signed by") {
                    Text(status.signingAuthority ?? (status.isAdHoc ? "ad-hoc (local build)" : "—"))
                        .font(.callout)
                        .foregroundStyle(status.signingAuthority == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                LabeledContent("Team ID") {
                    Text(status.teamIdentifier ?? "—")
                        .font(.callout.monospaced())
                        .foregroundStyle(status.teamIdentifier == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .textSelection(.enabled)
                }
                integrityRow(
                    ok: status.isValidSignature,
                    okText: status.isAdHoc ? "Signature valid (ad-hoc)" : "Signature valid",
                    badText: "Signature invalid"
                )
                integrityRow(
                    ok: status.isNotarized,
                    okText: "Notarized by Apple",
                    badText: status.isAdHoc ? "Not notarized (local build)" : "Not notarized",
                    warnOnly: status.isAdHoc
                )
                if let source = status.gatekeeperSource {
                    LabeledContent("Gatekeeper") {
                        Text(source).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if status.gatekeeperDisabled {
                    Label(
                        "Gatekeeper assessment is disabled on this Mac, so it would accept any app. The notarization result above comes from the ticket stapled to the bundle, not from Gatekeeper.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                if let err = status.error {
                    Text(err)
                        .font(.caption.monospaced())
                        .foregroundStyle(status.isAdHoc ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            } else {
                Text(signature.isChecking ? "Checking…" : "Not checked yet")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Re-check") { Task { await signature.check() } }
                    .controlSize(.small)
                    .disabled(signature.isChecking)
                if signature.isChecking { ProgressView().controlSize(.small) }
                Spacer()
                if let status = signature.status {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: status.bundlePath)]
                        )
                    } label: {
                        Image(systemName: "folder")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .help(status.bundlePath)
                }
            }
        } header: {
            Text("App integrity")
        } footer: {
            Text("""
                 Confirms this copy of Marina is genuinely signed by the \
                 developer and notarized by Apple — verifiable on any Mac, \
                 offline, against Apple's public roots and none of the \
                 developer's credentials. It does not attest which source \
                 commit built the binary; that needs build provenance \
                 (Sigstore/SLSA), a different kind of check.
                 """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func integrityRow(ok: Bool, okText: String, badText: String, warnOnly: Bool = false) -> some View {
        let tint: Color = ok ? .green : (warnOnly ? .orange : .red)
        let symbol = ok ? "checkmark.seal.fill" : (warnOnly ? "exclamationmark.triangle.fill" : "xmark.seal.fill")
        return HStack(spacing: 5) {
            Image(systemName: symbol).imageScale(.small)
            Text(ok ? okText : badText)
        }
        .font(.callout)
        .foregroundStyle(tint)
    }
}

/// One `marina doctor` check: status glyph, message, and — when it failed —
/// the detail and the command that repairs it.
private struct DoctorCheckRow: View {
    let check: DoctorCheck
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .imageScale(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(check.title).font(.callout.weight(.medium))
                    Text(check.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if let fixed = check.fixed {
                    Text(fixed ? "FIXED" : "FIX FAILED")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill((fixed ? Color.green : Color.red).opacity(0.18)))
                        .foregroundStyle(fixed ? Color.green : Color.red)
                }
            }
            if let detail = check.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .padding(.leading, 20)
            }
            if let fixError = check.fixError, !fixError.isEmpty {
                Text(fixError)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(.leading, 20)
            }
            if check.status != .ok, let fix = check.fix, !fix.isEmpty, !check.fixIsCommand {
                Text(fix)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 20)
            } else if check.status != .ok, let fix = check.fix, !fix.isEmpty {
                HStack(spacing: 6) {
                    Text(fix)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.secondary.opacity(0.12))
                        )
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fix, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the fix command")
                }
                .padding(.leading, 20)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch check.status {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private var tint: Color {
        switch check.status {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .red
        case .unknown: return .secondary
        }
    }
}
