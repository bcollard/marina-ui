import Foundation

/// Reads and drives the Docker daemon inside the marina guest VM over the same
/// SSH ControlMaster socket marina already keeps open (see `GuestSSH`).
///
/// One `docker ps` round-trip carries every field the UI needs — image, state,
/// ports, networks, mounts and labels — so there is no follow-up `docker
/// inspect` per container.
struct DockerClient: Sendable {
    let guest: GuestSSH

    /// Tab-separated so the parser survives the commas inside `.Ports`,
    /// `.Networks`, `.Mounts` and `.Labels`. Docker forbids tabs in none of
    /// these in principle, but every value we read here comes from image
    /// metadata and container config that in practice never contains one.
    ///
    /// Every label the app reasons about gets its **own column** via
    /// `{{.Label "…"}}`. `{{.Labels}}` comma-joins the whole map without
    /// escaping commas inside values, and two labels we care about routinely
    /// contain them — `com.docker.compose.project.config_files` (one per `-f`)
    /// and `com.docker.compose.depends_on` — so parsing that column would
    /// silently mangle exactly the labels that drive grouping. It stays last,
    /// for display only.
    private static let psFormat = [
        "{{.ID}}", "{{.Names}}", "{{.Image}}", "{{.State}}", "{{.Status}}",
        "{{.Ports}}", "{{.CreatedAt}}", "{{.Command}}", "{{.Networks}}",
        "{{.Mounts}}",
        #"{{.Label "io.x-k8s.kind.cluster"}}"#,
        #"{{.Label "io.x-k8s.kind.role"}}"#,
        #"{{.Label "com.docker.compose.project"}}"#,
        #"{{.Label "com.docker.compose.service"}}"#,
        #"{{.Label "com.docker.compose.container-number"}}"#,
        #"{{.Label "com.docker.compose.oneoff"}}"#,
        #"{{.Label "com.docker.compose.project.working_dir"}}"#,
        #"{{.Label "com.docker.compose.project.config_files"}}"#,
        "{{.Labels}}",
    ].joined(separator: "\t")

    /// Sentinel between the two sections of the list command's output. Not a
    /// substring of any container id, image ref, or JSON we parse.
    private static let sectionMarker = "@@MARINA-LABELS@@"

    /// Per-container detail that `docker ps` can't express, as JSON.
    ///
    /// Labels because `{{.Labels}}` can't be trusted (see `psFormat`), mounts
    /// because the `{{.Mounts}}` column flattens binds and volumes into one
    /// undifferentiated list with no destination. It rides the *same* SSH
    /// round-trip — the network hop is the expensive part, not the second
    /// local docker call.
    private static let inspectDetail =
        "docker ps -aq --no-trunc | xargs -r docker inspect"
        + " --format '{{.Id}}\t{{json .Config.Labels}}\t{{json .Mounts}}'"

    /// Every container in the VM, running or not.
    func list() async throws -> [DockerContainer] {
        let out = try await guest.run(
            "docker ps -a --no-trunc --format '\(Self.psFormat)'"
            + "; echo '\(Self.sectionMarker)'; \(Self.inspectDetail) 2>/dev/null"
        )
        let sections = out.components(separatedBy: Self.sectionMarker)
        let detail = sections.count > 1 ? Self.parseInspectDetail(sections[1]) : [:]
        return sections[0]
            .split(whereSeparator: \.isNewline)
            .compactMap { Self.parse(String($0)) }
            .map { container in
                // Behavior never depends on this: if the inspect pass failed,
                // the container keeps its (imperfect) ps-derived label map and
                // every classification still works off the dedicated columns.
                guard let d = detail[container.id] else { return container }
                return container.withInspected(labels: d.labels, mounts: d.mounts)
            }
    }

    /// `<64-char id>\t<labels JSON>\t<mounts JSON>` per line.
    static func parseInspectDetail(
        _ block: String
    ) -> [String: (labels: [String: String], mounts: [DockerContainer.MountDetail])] {
        var out: [String: (labels: [String: String], mounts: [DockerContainer.MountDetail])] = [:]
        let decoder = JSONDecoder()
        for line in block.split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 3, !parts[0].isEmpty else { continue }
            // `null` decodes to nil for a container with no labels / no mounts.
            let labels = parts[1].data(using: .utf8).flatMap {
                try? decoder.decode([String: String]?.self, from: $0)
            } ?? [:]
            let mounts = parts[2].data(using: .utf8).flatMap {
                try? decoder.decode([DockerContainer.MountDetail]?.self, from: $0)
            } ?? []
            out[parts[0]] = (labels, mounts)
        }
        return out
    }

    /// Tail a container's combined stdout/stderr. `--timestamps` is deliberately
    /// off: the entries are usually already timestamped by the app itself.
    func logs(id: String, lines: Int = 200, timestamps: Bool = false) async throws -> String {
        // docker writes container stdout to our stdout and stderr to stderr;
        // 2>&1 in the guest shell merges them in the order they were written.
        try await guest.run("docker logs --tail \(lines)\(timestamps ? " --timestamps" : "") \(id) 2>&1")
    }

    func start(id: String) async throws -> String { try await guest.run("docker start \(id)") }
    func stop(id: String) async throws -> String { try await guest.run("docker stop \(id)") }
    func restart(id: String) async throws -> String { try await guest.run("docker restart \(id)") }

    /// Start/stop every container of a compose stack in one round-trip.
    ///
    /// Deliberately `docker start`/`stop` on the specific ids rather than the
    /// real `docker compose up`/`down` in the stack's working directory: this
    /// project has already lost a kind node to compose's orphan sweep on `up`
    /// (see CLAUDE.md), and `down` would remove the containers outright. Ids
    /// are always docker's own hex container ids, never interpolated from
    /// anything a container image or label could influence.
    func start(ids: [String]) async throws -> String {
        try await guest.run("docker start \(ids.joined(separator: " "))")
    }

    func stop(ids: [String]) async throws -> String {
        try await guest.run("docker stop \(ids.joined(separator: " "))")
    }

    /// Force-remove every container of a compose stack — `-f` stops a running
    /// container before removing it, so this is the whole `stop` + `rm` in one
    /// call. The final, irreversible half of the stack lifecycle; the UI gates
    /// it behind a confirmation dialog.
    func remove(ids: [String]) async throws -> String {
        try await guest.run("docker rm -f \(ids.joined(separator: " "))")
    }

    // MARK: - Parsing

    static func parse(_ line: String) -> DockerContainer? {
        let f = line.components(separatedBy: "\t")
        guard f.count >= 19, !f[0].isEmpty else { return nil }
        /// An absent label renders as the empty string, not as a missing column.
        func label(_ i: Int) -> String? {
            let v = f[i].trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        return DockerContainer(
            id: f[0],
            name: f[1],
            image: f[2],
            state: f[3].lowercased(),
            status: f[4],
            ports: parsePorts(f[5]),
            createdAt: parseDate(f[6]),
            command: f[7].trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
            networks: splitList(f[8]),
            mounts: splitList(f[9]),
            // Filled in by the inspect pass; the ps column is the fallback.
            mountDetails: [],
            kindCluster: label(10),
            kindRole: label(11),
            compose: label(12).map { project in
                DockerContainer.ComposeMembership(
                    project: project,
                    service: label(13),
                    containerNumber: label(14).flatMap(Int.init),
                    // Compose writes Go's "True"/"False", not JSON's lowercase.
                    isOneOff: label(15)?.lowercased() == "true",
                    workingDir: label(16),
                    configFiles: splitList(f[17])
                )
            },
            labels: parseLabels(f[18])
        )
    }

    private static func splitList(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func parseLabels(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for entry in splitList(s) {
            guard let eq = entry.firstIndex(of: "=") else {
                out[entry] = ""
                continue
            }
            out[String(entry[entry.startIndex..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return out
    }

    /// Go's `time.Time` default layout, e.g. "2026-09-07 09:32:13 +0200 CEST".
    /// The trailing zone abbreviation is dropped — it is ambiguous across
    /// locales and the numeric offset right before it is unambiguous.
    private static func parseDate(_ s: String) -> Date? {
        let parts = s.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        return dateFormatter.date(from: parts.prefix(3).joined(separator: " "))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    /// Parse docker's port column: comma-separated `0.0.0.0:5050->5050/tcp`
    /// (published), `[::]:5050->5050/tcp` (the IPv6 half of the same publish)
    /// or a bare `5000/tcp` (exposed but not published).
    ///
    /// Docker lists a dual-stack publish twice, once per address family. We keep
    /// the first entry per (host port, container port, protocol) — the IPv4 one,
    /// which is the address that is actually routable from the macOS host.
    static func parsePorts(_ s: String) -> [DockerContainer.PortMapping] {
        var seen = Set<String>()
        var out: [DockerContainer.PortMapping] = []
        for entry in splitList(s) {
            guard let mapping = parsePort(entry) else { continue }
            let key = "\(mapping.hostPort ?? -1)/\(mapping.containerPort)/\(mapping.proto)"
            guard seen.insert(key).inserted else { continue }
            out.append(mapping)
        }
        return out
    }

    private static func parsePort(_ entry: String) -> DockerContainer.PortMapping? {
        let sides = entry.components(separatedBy: "->")
        // The container side (always last) is "<port>/<proto>".
        guard let containerSide = sides.last else { return nil }
        let cParts = containerSide.split(separator: "/")
        guard let containerPort = Int(cParts.first ?? "") else { return nil }
        let proto = cParts.count > 1 ? String(cParts[1]) : "tcp"

        guard sides.count == 2 else {
            return DockerContainer.PortMapping(
                hostIP: nil, hostPort: nil, containerPort: containerPort, proto: proto
            )
        }
        // Host side: "0.0.0.0:5050" or "[::]:5050" or just "5050".
        let hostSide = sides[0]
        guard let colon = hostSide.lastIndex(of: ":") else {
            return DockerContainer.PortMapping(
                hostIP: nil, hostPort: Int(hostSide), containerPort: containerPort, proto: proto
            )
        }
        var ip = String(hostSide[hostSide.startIndex..<colon])
        if ip.hasPrefix("["), ip.hasSuffix("]") { ip = String(ip.dropFirst().dropLast()) }
        return DockerContainer.PortMapping(
            hostIP: ip.isEmpty ? nil : ip,
            hostPort: Int(hostSide[hostSide.index(after: colon)...]),
            containerPort: containerPort,
            proto: proto
        )
    }
}
