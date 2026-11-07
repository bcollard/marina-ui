import Foundation

/// Wrapper around the `marina` CLI. Read operations prefer structured output;
/// write operations are fire-and-forget with combined stdout/stderr captured for logging.
enum MarinaCLI {
    static let executable = "marina"

    enum CLIError: Error, LocalizedError {
        case notInstalled
        case command(String, Int32, String)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "marina CLI not found in PATH"
            case .command(let cmd, let code, let stderr):
                return "marina \(cmd) exited \(code): \(stderr)"
            case .decode(let m):
                return "Failed to decode marina output: \(m)"
            }
        }
    }

    static func listClusters() async throws -> [KindCluster] {
        let result = try await ProcessRunner.run(executable, ["cluster", "list", "-o", "json"])
        guard result.ok else {
            throw CLIError.command("cluster list", result.exitCode, result.stderr)
        }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if stdout.isEmpty || stdout == "null" { return [] }
        guard let data = stdout.data(using: .utf8) else {
            throw CLIError.decode("non-utf8 output")
        }
        do {
            return try JSONDecoder().decode([KindCluster].self, from: data)
        } catch {
            throw CLIError.decode(error.localizedDescription)
        }
    }

    /// `marina fleet describe <name> -o json`: members, their options and
    /// addons, and the fleet's manifest (marina v0.3.10+ for the latter two).
    static func describeFleet(_ name: String) async throws -> FleetDescription {
        let result = try await ProcessRunner.run(executable, ["fleet", "describe", name, "-o", "json"])
        guard result.ok else {
            throw CLIError.command("fleet describe", result.exitCode, result.stderr)
        }
        guard let data = result.stdout.data(using: .utf8) else {
            throw CLIError.decode("non-utf8 output")
        }
        do {
            return try JSONDecoder().decode(FleetDescription.self, from: data)
        } catch {
            throw CLIError.decode(error.localizedDescription)
        }
    }

    /// Start (or finish provisioning) the VM. Long-running.
    static func up() async throws -> ProcessResult {
        try await ProcessRunner.run(executable, ["up"])
    }

    /// Stop the VM.
    static func down() async throws -> ProcessResult {
        try await ProcessRunner.run(executable, ["down"])
    }

    /// Create a new kind cluster with the given name.
    static func createCluster(name: String) async throws -> ProcessResult {
        try await ProcessRunner.run(executable, ["cluster", "create", name])
    }

    /// Set/overwrite a node label on an existing cluster (marina 0.1.35+):
    /// `marina cluster label <name> -l key=value`. This is marina's canonical
    /// relabel path (shared with create-time labeling); prefer it over a raw
    /// kubectl label so behavior stays consistent.
    static func labelCluster(name: String, key: String, value: String) async throws -> ProcessResult {
        try await ProcessRunner.run(executable, ["cluster", "label", name, "-l", "\(key)=\(value)"])
    }

    /// Delete a kind cluster by name. `-y` skips the interactive confirmation
    /// prompt marina shows by default (which would otherwise hang our Process).
    static func deleteCluster(name: String) async throws -> ProcessResult {
        try await ProcessRunner.run(executable, ["cluster", "delete", name, "-y"])
    }

    /// Delete every cluster in a fleet (marina 0.1.37+). marina resolves the
    /// members itself, by the `marina.run/fleet` node label inside the guest,
    /// so a member whose labels the UI failed to fetch is still included.
    static func deleteFleet(name: String) async throws -> ProcessResult {
        try await ProcessRunner.run(executable, ["fleet", "delete", name, "-y"])
    }

    /// Run `marina doctor -o json`, optionally applying the repairs marina can
    /// perform itself (`--fix`).
    ///
    /// The report is on stdout; marina's own logging goes to stderr, so we
    /// decode stdout alone. `doctor` exits 0 even when checks fail (the report
    /// carries `ok: false`), but we decode regardless of exit code so a future
    /// marina that starts signalling failure through the exit status still
    /// renders its report.
    ///
    /// `--fix` shells out to `sudo` for the macOS route repair. Launched from
    /// the app bundle there is no controlling terminal, so sudo fails fast with
    /// "no tty present" rather than blocking on a password prompt — that lands
    /// in the check's `fixError` and the UI offers the command to run by hand.
    static func doctor(fix: Bool = false) async throws -> DoctorReport {
        var args = ["doctor", "-o", "json"]
        if fix { args.append("--fix") }
        let result = try await ProcessRunner.run(executable, args)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = stdout.data(using: .utf8), !stdout.isEmpty else {
            throw CLIError.command("doctor", result.exitCode, result.stderr)
        }
        do {
            return try JSONDecoder().decode(DoctorReport.self, from: data)
        } catch {
            throw CLIError.decode(error.localizedDescription)
        }
    }

    /// Read `marina status -o json`.
    ///
    /// The UI reads VM liveness and the cluster list from cheaper sources, so
    /// this is called only for what has no filesystem equivalent — the mount
    /// list, which comes from the Lima instance config and therefore answers
    /// "what does the VM actually share" rather than "what does the config
    /// file ask for". Costs one CLI invocation (~350 ms), so it rides
    /// `refreshAll()` and never a poll loop.
    ///
    /// `mounts` is absent on marina older than 0.1.59; the optional field
    /// decodes to nil and the UI simply omits the section.
    static func status() async throws -> MarinaStatus {
        let result = try await ProcessRunner.run(executable, ["status", "-o", "json"])
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = stdout.data(using: .utf8), !stdout.isEmpty else {
            throw CLIError.command("status", result.exitCode, result.stderr)
        }
        do {
            return try JSONDecoder().decode(MarinaStatus.self, from: data)
        } catch {
            throw CLIError.decode(error.localizedDescription)
        }
    }

    /// Read `marina dns list -o json` (marina 0.2.0+): every name published in
    /// the local zone. One `etcdctl` over SSH inside marina, so it rides
    /// `refreshAll()` and cluster selection, never a poll loop.
    static func dnsRecords() async throws -> [LocalDNSRecord] {
        let result = try await ProcessRunner.run(executable, ["dns", "list", "-o", "json"])
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.ok, let data = stdout.data(using: .utf8), !stdout.isEmpty else {
            throw CLIError.command("dns list", result.exitCode, result.stderr)
        }
        do {
            return try JSONDecoder().decode([LocalDNSRecord].self, from: data)
        } catch {
            throw CLIError.decode(error.localizedDescription)
        }
    }

    /// Install ExternalDNS and the CoreDNS forward on an existing cluster
    /// (`marina dns attach`). Restarts the cluster's CoreDNS, so in-cluster
    /// DNS blips — the view confirms first.
    static func dnsAttach(cluster: String) async throws -> ProcessResult {
        try await ProcessRunner.run(executable, ["dns", "attach", cluster])
    }

    /// Read `marina ca status -o json` (marina 0.2.2+): the root CA, its
    /// keychain trust, and which clusters/fleets have a wildcard. Reads files
    /// under `~/.marina/pki` on the Mac (~30 ms), so it rides `refreshAll()`.
    static func caStatus() async throws -> LocalCAStatus {
        let result = try await ProcessRunner.run(executable, ["ca", "status", "-o", "json"])
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.ok, let data = stdout.data(using: .utf8), !stdout.isEmpty else {
            throw CLIError.command("ca status", result.exitCode, result.stderr)
        }
        do {
            return try JSONDecoder().decode(LocalCAStatus.self, from: data)
        } catch {
            throw CLIError.decode(error.localizedDescription)
        }
    }

    /// Issue (or renew) a cluster's wildcard and install it (`marina ca
    /// attach`). Installing the root in the nodes restarts their containerd —
    /// the view confirms first.
    static func caAttach(cluster: String) async throws -> ProcessResult {
        try await ProcessRunner.run(executable, ["ca", "attach", cluster])
    }

    /// Copy the cluster's wildcard Secret (or, with `fleet`, its fleet's) into
    /// another namespace — an Ingress reads its TLS Secret from its own.
    static func caSecret(cluster: String, namespace: String, fleet: Bool) async throws -> ProcessResult {
        var args = ["ca", "secret", cluster, "-n", namespace]
        if fleet { args.append("--fleet") }
        return try await ProcessRunner.run(executable, args)
    }

    /// The root CA certificate, PEM (`marina ca cert`).
    static func caCert() async throws -> String {
        let result = try await ProcessRunner.run(executable, ["ca", "cert"])
        guard result.ok else { throw CLIError.command("ca cert", result.exitCode, result.stderr) }
        return result.stdout
    }

    /// Return marina version string, e.g. "marina 0.1.25".
    static func version() async throws -> String {
        let result = try await ProcessRunner.run(executable, ["version"])
        guard result.ok else {
            throw CLIError.command("version", result.exitCode, result.stderr)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
