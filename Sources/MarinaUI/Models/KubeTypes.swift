import Foundation

/// Minimal subset of the Kubernetes API JSON we care about. Decoded from
/// `kubectl get ... -o json`. Only the fields actually rendered are modeled —
/// kubectl returns far more.

struct KubeList<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
}

struct KubeNode: Decodable, Sendable, Hashable, Identifiable {
    var id: String { metadata.name }
    let metadata: ObjectMeta
    let status: Status

    struct Status: Decodable, Sendable, Hashable {
        let conditions: [Condition]?
        let nodeInfo: NodeInfo?
        let capacity: ResourceList?

        struct Condition: Decodable, Sendable, Hashable {
            let type: String
            let status: String
        }
        struct NodeInfo: Decodable, Sendable, Hashable {
            let kubeletVersion: String?
            let osImage: String?
            let kernelVersion: String?
            let containerRuntimeVersion: String?
            let architecture: String?
        }
    }

    var ready: Bool {
        status.conditions?.first { $0.type == "Ready" }?.status == "True"
    }
}

struct KubePod: Decodable, Sendable, Hashable, Identifiable {
    var id: String { "\(metadata.namespace ?? "")/\(metadata.name)" }
    let metadata: ObjectMeta
    let status: Status

    struct Status: Decodable, Sendable, Hashable {
        let phase: String?
        let podIP: String?
    }
}

struct KubeDeployment: Decodable, Sendable, Hashable, Identifiable {
    var id: String { "\(metadata.namespace ?? "")/\(metadata.name)" }
    let metadata: ObjectMeta
    let spec: Spec?
    let status: Status

    struct Spec: Decodable, Sendable, Hashable {
        let template: Template?
        struct Template: Decodable, Sendable, Hashable {
            let spec: PodSpec?
        }
        struct PodSpec: Decodable, Sendable, Hashable {
            let containers: [Container]?
        }
        struct Container: Decodable, Sendable, Hashable {
            let args: [String]?
        }
    }

    /// Every container arg, flattened.
    var containerArgs: [String] {
        spec?.template?.spec?.containers?.flatMap { $0.args ?? [] } ?? []
    }

    struct Status: Decodable, Sendable, Hashable {
        let replicas: Int?
        let readyReplicas: Int?
        let availableReplicas: Int?
    }

    var isReady: Bool {
        let desired = status.replicas ?? 0
        let ready = status.readyReplicas ?? 0
        return desired > 0 && ready >= desired
    }
}

struct ObjectMeta: Decodable, Sendable, Hashable {
    let name: String
    let namespace: String?
    let labels: [String: String]?
    let annotations: [String: String]?
}

struct KubeService: Decodable, Sendable, Hashable, Identifiable {
    var id: String { "\(metadata.namespace ?? "")/\(metadata.name)" }
    let metadata: ObjectMeta
    let spec: Spec
    let status: Status?

    struct Spec: Decodable, Sendable, Hashable {
        let type: String?
        let ports: [Port]?
        let clusterIP: String?
        let selector: [String: String]?
    }

    struct Status: Decodable, Sendable, Hashable {
        let loadBalancer: LoadBalancer?
        struct LoadBalancer: Decodable, Sendable, Hashable {
            let ingress: [Ingress]?
            struct Ingress: Decodable, Sendable, Hashable {
                let ip: String?
                let hostname: String?
            }
        }
    }

    struct Port: Decodable, Sendable, Hashable, Identifiable {
        var id: String { "\(port)-\(protocolValue)-\(name ?? "")" }
        let name: String?
        let port: Int
        let protocolValue: String
        /// `spec.ports[].appProtocol`: an IANA name (`http`, `https`) or a
        /// prefixed one (`kubernetes.io/h2c`, `kubernetes.io/ws`).
        let appProtocol: String?
        let nodePort: Int?
        let targetPortString: String?

        enum CodingKeys: String, CodingKey {
            case name, port, nodePort, appProtocol
            case protocolValue = "protocol"
            case targetPort
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decodeIfPresent(String.self, forKey: .name)
            self.port = try c.decode(Int.self, forKey: .port)
            self.protocolValue = try c.decodeIfPresent(String.self, forKey: .protocolValue) ?? "TCP"
            self.appProtocol = try c.decodeIfPresent(String.self, forKey: .appProtocol)
            self.nodePort = try c.decodeIfPresent(Int.self, forKey: .nodePort)
            // targetPort is either int or string ("http"); normalize to string.
            if let intVal = try? c.decodeIfPresent(Int.self, forKey: .targetPort) {
                self.targetPortString = String(intVal)
            } else if let strVal = try? c.decodeIfPresent(String.self, forKey: .targetPort) {
                self.targetPortString = strVal
            } else {
                self.targetPortString = nil
            }
        }
    }

    var externalIPs: [String] {
        status?.loadBalancer?.ingress?.compactMap { $0.ip } ?? []
    }

    var isLoadBalancer: Bool { spec.type == "LoadBalancer" }

    /// Names requested with `external-dns.kubernetes.io/hostname` (comma-
    /// separated). marina's ExternalDNS reads only this prefix; the old
    /// `external-dns.alpha.kubernetes.io/` one is ignored, so it is here too.
    var hostnameAnnotation: [String] {
        (metadata.annotations?["external-dns.kubernetes.io/hostname"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }
}

struct ResourceList: Decodable, Sendable, Hashable {
    let cpu: String?
    let memory: String?
    let pods: String?
}
