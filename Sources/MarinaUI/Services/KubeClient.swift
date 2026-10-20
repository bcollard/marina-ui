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
