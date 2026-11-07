import Foundation

/// Thin wrapper around the local `kubectl` binary scoped to one kubeconfig.
/// We don't link a Swift k8s client yet — shelling out matches the rest of
/// the app and avoids implementing mTLS auth ourselves. Replace with a native
/// URLSession client when we need streaming watches.
struct KubeClient: Sendable {
    let kubeconfigPath: String

    enum KubeError: Error, LocalizedError {
        case command(String, Int32, String)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .command(let cmd, let code, let stderr):
                return "kubectl \(cmd) exited \(code): \(stderr)"
            case .decode(let m):
                return "Failed to decode kubectl output: \(m)"
            }
        }
    }

    func listNodes() async throws -> [KubeNode] {
        try await getList("nodes", as: KubeNode.self)
    }

    /// Pods across all namespaces.
    func listPods() async throws -> [KubePod] {
        try await getList("pods", as: KubePod.self, allNamespaces: true)
    }

    /// Services across all namespaces.
    func listServices() async throws -> [KubeService] {
        try await getList("services", as: KubeService.self, allNamespaces: true)
    }

    func getDeployment(_ name: String, namespace: String) async -> KubeDeployment? {
        let args = baseArgs(["get", "deployment", name, "-n", namespace, "-o", "json"])
        guard let result = try? await ProcessRunner.run("kubectl", args), result.ok else {
            return nil
        }
        guard let data = result.stdout.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(KubeDeployment.self, from: data)
    }

    /// True when metrics-server is installed and at least one replica is ready.
    func metricsServerReady() async -> Bool {
        guard let dep = await getDeployment("metrics-server", namespace: "kube-system") else {
            return false
        }
        return dep.isReady
    }

    /// State of marina's per-cluster ExternalDNS (`external-dns/external-dns`).
    /// nil when kubectl failed for another reason than NotFound — an
    /// unreachable API server must not read as "not attached".
    func externalDNS() async -> ExternalDNSInfo? {
        let args = baseArgs(["get", "deployment", "external-dns", "-n", "external-dns", "-o", "json"])
        guard let result = try? await ProcessRunner.run("kubectl", args) else { return nil }
        if !result.ok {
            return result.stderr.contains("NotFound")
                ? ExternalDNSInfo(state: .missing, publishesIngress: nil) : nil
        }
        guard let data = result.stdout.data(using: .utf8),
              let dep = try? JSONDecoder().decode(KubeDeployment.self, from: data)
        else { return nil }
        return ExternalDNSInfo(state: dep.isReady ? .ready : .notReady,
                               publishesIngress: dep.containerArgs.contains("--source=ingress"))
    }

    /// Creation timestamp of the kube-system namespace — a reliable proxy for
    /// when the cluster itself was bootstrapped, since kind creates it as part
    /// of cluster setup. Returns nil when the cluster isn't reachable.
    func kubeSystemCreationTime() async -> Date? {
        let args = baseArgs([
            "get", "ns", "kube-system",
            "-o", "jsonpath={.metadata.creationTimestamp}",
        ])
        guard let result = try? await ProcessRunner.run("kubectl", args), result.ok else {
            return nil
        }
        let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    func clusterVersion() async -> String? {
        let args = baseArgs(["version", "-o", "json"])
        guard let result = try? await ProcessRunner.run("kubectl", args), result.ok else {
            return nil
        }
        struct V: Decodable { let serverVersion: Server? }
        struct Server: Decodable { let gitVersion: String? }
        guard let data = result.stdout.data(using: .utf8),
              let v = try? JSONDecoder().decode(V.self, from: data)
        else { return nil }
        return v.serverVersion?.gitVersion
    }

    // MARK: - Workloads tab

    /// Deployments, StatefulSets, DaemonSets, Jobs, CronJobs, and the
    /// ReplicaSets that link Deployment pods to their Deployment. One call.
    func listWorkloadObjects() async throws -> [Workload] {
        try await getList("deployments,statefulsets,daemonsets,jobs,cronjobs,replicasets",
                          as: Workload.self, allNamespaces: true)
    }

    func listWorkloadPods() async throws -> [WorkloadPod] {
        try await getList("pods", as: WorkloadPod.self, allNamespaces: true)
    }

    struct LogOptions: Sendable, Hashable {
        var tail: Int = 500
        var timestamps: Bool = false
        var previous: Bool = false
    }

    /// `kubectl logs` for one container of one pod.
    func podLogs(namespace: String, pod: String, container: String?, options: LogOptions) async throws -> String {
        var rest = ["logs", "-n", namespace, pod, "--tail=\(options.tail)"]
        if let container { rest += ["-c", container] }
        if options.timestamps { rest.append("--timestamps") }
        if options.previous { rest.append("--previous") }
        return try await runText(rest, what: "logs \(pod)")
    }

    /// Every container of every pod matching `selector`, interleaved per pod
    /// and prefixed `[pod/<name>/<container>]`, like `kubectl logs -l`.
    ///
    /// kubectl emits one pod's lines after another, so the lines are fetched
    /// with timestamps, merged in time order, and the timestamps dropped again
    /// unless the caller asked for them.
    func selectorLogs(namespace: String, selector: String, options: LogOptions) async throws -> String {
        let rest = ["logs", "-n", namespace, "-l", selector, "--all-containers", "--prefix",
                    "--max-log-requests=20", "--tail=\(options.tail)", "--timestamps"]
        let raw = try await runText(rest, what: "logs -l \(selector)")
        return Self.interleave(raw, keepTimestamps: options.timestamps)
    }

    /// Sorts `[pod/…] <RFC3339 timestamp> message` lines by timestamp (stable,
    /// so one pod's lines keep their order). A line without a timestamp — a
    /// continuation, or kubectl's own notice — stays after the line before it.
    /// kubectl trims trailing zeros (RFC3339Nano), so "…02.1Z" and "…02.12Z"
    /// do not compare as strings; pad the fraction to nine digits.
    static func sortKey(_ ts: String) -> String {
        let body = ts.hasSuffix("Z") ? String(ts.dropLast()) : ts
        let parts = body.split(separator: ".", maxSplits: 1)
        let frac = parts.count > 1 ? String(parts[1]) : ""
        return parts[0] + "." + frac.padding(toLength: 9, withPad: "0", startingAt: 0)
    }

    static func interleave(_ raw: String, keepTimestamps: Bool) -> String {
        struct Entry { let key: String; let index: Int; let text: String }
        var entries: [Entry] = []
        var lastKey = ""
        for (i, line) in raw.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var text = String(line)
            var key = lastKey
            if line.hasPrefix("[pod/"), let close = line.firstIndex(of: "]") {
                let prefix = line[...close]
                let rest = line[line.index(after: close)...].drop { $0 == " " }
                if let space = rest.firstIndex(of: " "), rest[rest.startIndex..<space].contains("T"),
                   rest.first?.isNumber == true {
                    key = Self.sortKey(String(rest[rest.startIndex..<space]))
                    if !keepTimestamps { text = prefix + " " + rest[rest.index(after: space)...] }
                }
            }
            lastKey = key
            entries.append(Entry(key: key, index: i, text: text))
        }
        if entries.last?.text.isEmpty == true { entries.removeLast() }
        return entries
            .sorted { $0.key == $1.key ? $0.index < $1.index : $0.key < $1.key }
            .map(\.text)
            .joined(separator: "\n")
    }

    /// `kubectl rollout restart <kind>/<name>`.
    func rolloutRestart(kind: String, namespace: String, name: String) async throws -> String {
        try await runText(["rollout", "restart", "\(kind.lowercased())/\(name)", "-n", namespace],
                          what: "rollout restart")
    }

    func deletePod(namespace: String, name: String) async throws -> String {
        try await runText(["delete", "pod", name, "-n", namespace, "--wait=false"], what: "delete pod")
    }

    private func runText(_ rest: [String], what: String) async throws -> String {
        let result = try await ProcessRunner.run("kubectl", baseArgs(rest))
        guard result.ok else { throw KubeError.command(what, result.exitCode, result.stderr) }
        return result.stdout
    }

    private func getList<T: Decodable & Sendable>(
        _ resource: String,
        as: T.Type,
        allNamespaces: Bool = false
    ) async throws -> [T] {
        var rest = ["get", resource, "-o", "json"]
        if allNamespaces { rest.append("-A") }
        let result = try await ProcessRunner.run("kubectl", baseArgs(rest))
        guard result.ok else {
            throw KubeError.command("get \(resource)", result.exitCode, result.stderr)
        }
        guard let data = result.stdout.data(using: .utf8) else {
            throw KubeError.decode("non-utf8 output")
        }
        do {
            return try JSONDecoder().decode(KubeList<T>.self, from: data).items
        } catch {
            throw KubeError.decode(error.localizedDescription)
        }
    }

    private func baseArgs(_ rest: [String]) -> [String] {
        ["--kubeconfig", kubeconfigPath] + rest
    }
}
