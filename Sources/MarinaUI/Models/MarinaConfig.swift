import Foundation

struct MarinaConfig: Sendable, Hashable, Decodable {
    let vm: VM
    let network: Network?
    let kind: Kind?
    let registries: Registries?

    struct VM: Sendable, Hashable, Decodable {
        let name: String
        let cpus: Int?
        let memory: String?
        let disk: String?
        let rosetta: Bool?
        /// Host directories shared into the guest over virtiofs (marina 0.1.59+).
        /// Only what's listed here resolves for a `docker run -v <host path>`.
        let mounts: [Mount]?
        /// Extra certificate authorities the VM, the mirrors and the kind nodes
        /// trust (marina 0.1.60+).
        let caCerts: CACerts?

        struct Mount: Sendable, Hashable, Decodable {
            let location: String
            let mountPoint: String?
            let writable: Bool?
        }

        struct CACerts: Sendable, Hashable, Decodable {
            let files: [String]?
        }
    }

    struct Network: Sendable, Hashable, Decodable {
        let kindBridgeCIDR: String?
        let disablePortMirroring: Bool?
        /// Explicit HTTP(S) proxy for dockerd, the mirrors and the kind nodes
        /// (marina 0.1.60+). Absent means marina inherits whatever macOS has —
        /// which is the common case, so absence is not "no proxy".
        let proxy: Proxy?
        /// Local DNS zone settings (marina 0.2.0+). Only `nameTemplate` and
        /// `ingress` are read from here; live state comes from `marina status`.
        let dns: DNS?

        struct DNS: Sendable, Hashable, Decodable {
            /// ExternalDNS `--fqdn-template` relative to `<cluster>.<domain>`
            /// (marina 0.2.2+). nil means marina's default `{{.Name}}.{{.Namespace}}`.
            let nameTemplate: String?
            /// Whether ExternalDNS also publishes Ingress hosts (`--source=ingress`,
            /// marina 0.3.0+). nil means off — marina's default since 0.3.0.
            let ingress: Bool?
        }

        struct Proxy: Sendable, Hashable, Decodable {
            let http: String?
            let https: String?
            let noProxy: [String]?
            let inheritFromHost: Bool?

            /// marina's own rule: an explicit proxy is configured only when a
            /// URL is set. `inheritFromHost` alone leaves it to macOS.
            var isExplicit: Bool {
                !(http ?? "").isEmpty || !(https ?? "").isEmpty
            }

            /// nil in the file means true.
            var inheritsFromHost: Bool { inheritFromHost ?? true }
        }
    }

    struct Kind: Sendable, Hashable, Decodable {
        let nodeVersion: String?
        let metalLBVersion: String?
    }

    struct Registries: Sendable, Hashable, Decodable {
        let mirrors: [Mirror]?
        let cacheStorage: String?

        struct Mirror: Sendable, Hashable, Decodable {
            let name: String
            let port: Int
            let remoteURL: String
        }
    }
}
