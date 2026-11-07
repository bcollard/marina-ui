import Foundation

/// Decodes `marina fleet describe <name> -o json`.
///
/// `options`, `addons` and `manifest*` arrived in marina v0.3.10. Every one is
/// optional here, so an older CLI still renders the members.
struct FleetDescription: Decodable, Sendable, Hashable {
    let name: String
    let members: [Member]
    /// The manifest: the newest one a member recorded ("applied"), or one
    /// rebuilt from live state like `marina fleet export` ("exported").
    let manifest: String?
    let manifestSource: String?
    let appliedAt: String?

    var manifestWasApplied: Bool { manifestSource == "applied" }

    var appliedDate: Date? {
        appliedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    var readyCount: Int { members.filter(\.ready).count }

    struct Member: Decodable, Sendable, Hashable, Identifiable {
        var id: String { name }
        let name: String
        let num: Int
        let apiPort: Int
        let kubeconfigPath: String
        let nodes: Int
        let k8sVersion: String
        let ready: Bool
        let labels: [String: String]?
        /// The member's resolved manifest entry (marina-fleet record). nil for
        /// clusters created before marina kept one, or adopted without a manifest.
        let options: Options?
        let addons: Addons?

        var region: String? { labels?["topology.kubernetes.io/region"] }
        var zone: String? { labels?["topology.kubernetes.io/zone"] }

        /// Labels a user set: drops the kubelet's and the ones marina shows elsewhere.
        var customLabels: [(key: String, value: String)] {
            let hidden = ["kubernetes.io/", "beta.kubernetes.io/", "node-role.kubernetes.io/",
                          "node.kubernetes.io/", "topology.kubernetes.io/"]
            let fixed: Set<String> = ["managed-by", "marina.run/fleet", "ingress-ready"]
            return (labels ?? [:])
                .filter { kv in !fixed.contains(kv.key) && !hidden.contains { kv.key.hasPrefix($0) } }
                .sorted { $0.key < $1.key }
                .map { (key: $0.key, value: $0.value) }
        }
    }

    struct Options: Decodable, Sendable, Hashable {
        let dependsOn: [String]?
        let nodeVersion: String?
        let registries: Registries?
        let addons: DeclaredAddons?

        struct Registries: Decodable, Sendable, Hashable {
            /// nil = every mirror; [] = none; ["*"] = every mirror.
            let mirrors: [String]?
        }
        struct DeclaredAddons: Decodable, Sendable, Hashable {
            let metricsServer: DeclaredMetricsServer?
        }
        struct DeclaredMetricsServer: Decodable, Sendable, Hashable {
            let enabled: Bool
            let version: String?
        }

        /// Human summary of the mirror selection.
        var mirrorsSummary: String {
            guard let m = registries?.mirrors else { return "all mirrors" }
            if m.isEmpty { return "no mirrors" }
            if m.contains("*") { return "all mirrors" }
            return m.joined(separator: ", ")
        }
    }

    struct Addons: Decodable, Sendable, Hashable {
        let metricsServer: AddonStatus?
    }

    struct AddonStatus: Decodable, Sendable, Hashable {
        let installed: Bool
        let version: String?
        let ready: Bool
    }
}
