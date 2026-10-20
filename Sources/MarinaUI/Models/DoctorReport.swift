import Foundation

/// Decoded `marina doctor -o json`. The check `id`s are a documented, stable
/// contract on the marina side ("renaming one is a breaking change for anything
/// consuming `marina doctor -o json`"), so we key our icons/labels off them.
struct DoctorReport: Sendable, Hashable, Decodable {
    let ok: Bool
    let checks: [DoctorCheck]

    /// Checks that failed and that `marina doctor --fix` knows how to repair itself.
    var fixableFailures: [DoctorCheck] {
        checks.filter { $0.status == .fail && $0.fixable }
    }

    var failureCount: Int { checks.filter { $0.status == .fail }.count }
    var warningCount: Int { checks.filter { $0.status == .warn }.count }
}

struct DoctorCheck: Sendable, Hashable, Decodable, Identifiable {
    let id: String
    let status: Status
    let message: String
    let detail: String?
    /// Command the operator should run to repair this check by hand.
    let fix: String?
    /// Whether `marina doctor --fix` can repair it without the operator.
    let fixable: Bool
    /// Set only on a `--fix` run: whether the repair this run attempted worked.
    let fixed: Bool?
    let fixError: String?

    /// Unknown status strings decode to `.unknown` rather than failing the
    /// whole report — a newer marina adding a status must not blank the tab.
    enum Status: String, Sendable, Decodable {
        case ok, fail, warn, unknown

        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .unknown
        }
    }

    /// Human-readable title for the check, from its stable id. Unknown ids fall
    /// back to the id itself so a marina that adds a check still renders.
    var title: String {
        switch id {
        case "hostagent": return "Lima hostagent"
        case "vm": return "Virtual machine"
        case "route": return "macOS route"
        case "rosetta-host": return "Rosetta 2 (host)"
        case "ssh": return "SSH to guest"
        case "iptables": return "iptables no-NAT exemption"
        case "ip-forward": return "Guest IP forwarding"
        case "rosetta-vm": return "Rosetta 2 (VM)"
        case "proxy": return "HTTP proxy"
        case "dns": return "Local DNS"
        case "dns-system-resolver": return "Local DNS via macOS resolver"
        case "tls": return "Local CA"
        default: return id
        }
    }

    /// Whether `fix` is a command to paste into a terminal. Some fixes are a
    /// request for someone else — `dns-system-resolver` names the exemption an
    /// MDM admin has to add — and must not render as a shell command.
    var fixIsCommand: Bool {
        guard let fix else { return false }
        return fix.hasPrefix("marina ") || fix.hasPrefix("sudo ")
    }
}
