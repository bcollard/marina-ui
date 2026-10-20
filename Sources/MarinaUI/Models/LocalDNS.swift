import Foundation

/// One A record from `marina dns list -o json`. TXT ownership records are
/// already filtered out by marina.
struct LocalDNSRecord: Sendable, Hashable, Decodable, Identifiable {
    let name: String
    let ip: String

    var id: String { "\(name)→\(ip)" }
}

/// Why a name points at a Service's VIP.
enum DNSNameSource: Sendable, Hashable {
    /// The Service's `external-dns.kubernetes.io/hostname` annotation.
    case annotation
    /// `network.dns.nameTemplate` under the cluster zone.
    case automatic
    /// Published by something else on the same VIP — an Ingress host on an
    /// ingress controller's Service, typically.
    case sharedVIP
}

/// Decoded `marina ca status -o json` (marina 0.2.2+). Host-side only — it
/// reads `~/.marina/pki` — so it answers with the VM stopped.
struct LocalCAStatus: Sendable, Hashable, Decodable {
    let enabled: Bool
    let domain: String
    let root: String?
    let exists: Bool
    let trusted: Bool
    /// Root expiry, `YYYY-MM-DD`.
    let notAfter: String?
    /// Clusters with an issued wildcard.
    let clusters: [Zone]
    /// Fleets with an issued wildcard (marina 0.2.3+).
    let fleets: [Zone]?

    struct Zone: Sendable, Hashable, Decodable {
        let name: String
        /// `*.<name>.<domain>`.
        let wildcard: String
        let notAfter: String?
    }

    func cluster(_ name: String) -> Zone? { clusters.first { $0.name == name } }
    func fleet(_ name: String) -> Zone? { fleets?.first { $0.name == name } }
}

/// Which marina wildcard certificate covers a name, if any. A wildcard covers
/// exactly one label, so the default two-label automatic name
/// (`<svc>.<ns>.<cluster>.<domain>`) is **not** covered.
enum WildcardCoverage: Sendable, Hashable {
    /// `*.<cluster>.<domain>`, Secret `default/marina-wildcard-tls`.
    case cluster(wildcard: String)
    /// `*.<fleet>.<domain>`, Secret `default/marina-fleet-wildcard-tls`.
    case fleet(wildcard: String)

    var wildcard: String {
        switch self {
        case .cluster(let w), .fleet(let w): return w
        }
    }

    var secret: String {
        switch self {
        case .cluster: return "default/marina-wildcard-tls"
        case .fleet: return "default/marina-fleet-wildcard-tls"
        }
    }

    /// Whether `name` is exactly one label under `zone`.
    static func isOneLabel(_ name: String, under zone: String) -> Bool {
        guard name.hasSuffix("." + zone) else { return false }
        let label = name.dropLast(zone.count + 1)
        return !label.isEmpty && !label.contains(".")
    }
}

/// How a published name resolves on the Mac, through `/etc/resolver` — the
/// same path a browser or `curl` takes, unlike `dig`.
struct NameResolution: Sendable, Hashable {
    let timestamp: Date
    /// IPv4 addresses macOS returned; empty for NXDOMAIN or a timeout.
    let addresses: [String]
}

/// Whether a cluster's ExternalDNS is installed, from its deployment in the
/// `external-dns` namespace.
enum ExternalDNSState: Sendable, Hashable {
    case ready
    case notReady
    /// Created before `network.dns` was on (or the install failed):
    /// `marina dns attach` is the fix.
    case missing
}

/// A cluster's ExternalDNS deployment, from `external-dns/external-dns`.
struct ExternalDNSInfo: Sendable, Hashable {
    let state: ExternalDNSState
    /// Whether it runs `--source=ingress`. nil when it isn't installed.
    let publishesIngress: Bool?
}

/// Whether macOS's own resolver — the path curl and browsers take — answers
/// for the zone. Tested with `marina-probe.<domain>`, a record marina 0.3.3+
/// publishes at the zone apex pointing at the DNS server itself, so it works
/// with no cluster running. Same test as the `dns-system-resolver` doctor check.
enum SystemResolverState: Sendable, Hashable {
    case ok
    /// The server doesn't have the probe record: DNS was set up by an older
    /// marina. `marina up` writes it. Says nothing about the Mac's resolver.
    case probeMissing
    /// The server answers the probe, macOS doesn't: something sends the zone's
    /// lookups past `/etc/resolver`. `profile` is set when an MDM
    /// encrypted-DNS profile is installed — the usual cause.
    case bypassed(profile: ManagedDNSProfile?)

    static let probeLabel = "marina-probe"
}

/// An MDM-pushed encrypted DNS profile (`com.apple.dnsSettings.managed`). With
/// one installed, mDNSResponder sends lookups to its DoH/DoT server instead of
/// following `/etc/resolver`, unless its OnDemandRules exempt the domain.
struct ManagedDNSProfile: Sendable, Hashable {
    let path: String
    let dnsProtocol: String?
    let server: String?

    /// Where marina looks too (`localdns.FindManagedDNSProfiles`): the
    /// device-wide payload and the per-user copies under it.
    static func find() -> [ManagedDNSProfile] {
        let dir = "/Library/Managed Preferences"
        let file = "com.apple.dnsSettings.managed.plist"
        let fm = FileManager.default
        var paths = ["\(dir)/\(file)"]
        for sub in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            paths.append("\(dir)/\(sub)/\(file)")
        }
        return paths.filter { fm.fileExists(atPath: $0) }.map { path in
            var proto: String?, server: String?
            if let data = fm.contents(atPath: path),
               let root = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                (proto, server) = parse(root)
            }
            return ManagedDNSProfile(path: path, dnsProtocol: proto, server: server)
        }
    }

    /// The keys are searched for at any depth: Apple documents them inside a
    /// DNSSettings dictionary, but MDMs differ in how they nest the payload.
    private static func parse(_ root: Any) -> (String?, String?) {
        var proto: String?, server: String?
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                if proto == nil { proto = d["DNSProtocol"] as? String }
                if server == nil { server = (d["ServerURL"] as? String) ?? (d["ServerName"] as? String) }
                if server == nil { server = (d["ServerAddresses"] as? [Any])?.first as? String }
                for k in d.keys.sorted() { walk(d[k]!) }
            } else if let a = v as? [Any] {
                a.forEach(walk)
            }
        }
        walk(root)
        return (proto, server)
    }

    /// "DoH https://…" for display.
    var via: String {
        let s = [dnsProtocol, server].compactMap { $0 }.joined(separator: " ")
        return s.isEmpty ? "an encrypted DNS server" : s
    }
}

/// IPv4 CIDR membership, for telling whether a published address sits on the
/// kind bridge the Mac has a route to.
struct IPv4CIDR: Sendable, Hashable {
    let network: UInt32
    let mask: UInt32

    init?(_ cidr: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]), (0...32).contains(bits),
              let base = Self.parse(String(parts[0]))
        else { return nil }
        mask = bits == 0 ? 0 : UInt32.max << UInt32(32 - bits)
        network = base & mask
    }

    func contains(_ ip: String) -> Bool {
        guard let addr = Self.parse(ip) else { return false }
        return addr & mask == network
    }

    static func parse(_ ip: String) -> UInt32? {
        let octets = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for o in octets {
            guard let n = UInt8(o) else { return nil }
            value = value << 8 | UInt32(n)
        }
        return value
    }
}

/// Resolves a name with `getaddrinfo`, which on macOS goes through
/// mDNSResponder and so honours `/etc/resolver/<domain>`.
enum HostResolver {
    static func resolveIPv4(_ name: String) async -> [String] {
        await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(name, nil, &hints, &res) == 0, let first = res else { return [] }
            defer { freeaddrinfo(first) }
            var out: [String] = []
            var cur: UnsafeMutablePointer<addrinfo>? = first
            while let ai = cur {
                if let sa = ai.pointee.ai_addr, ai.pointee.ai_family == AF_INET {
                    var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                        let s = String(decoding: bytes, as: UTF8.self)
                        if !out.contains(s) { out.append(s) }
                    }
                }
                cur = ai.pointee.ai_next
            }
            return out
        }.value
    }
}
