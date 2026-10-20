import SwiftUI
import AppKit

/// Shown when macOS's own resolver doesn't answer for the zone. Every name then
/// fails in curl and browsers while the VM, the pods and `dig @server` are fine,
/// so it is said once, above the per-name dots, instead of as N red dots that
/// all point at /etc/resolver.
struct SystemResolverBanner: View {
    let state: SystemResolverState
    let domain: String
    @State private var copied = false

    var body: some View {
        switch state {
        case .ok:
            EmptyView()
        case .probeMissing:
            Label("Can't test whether this Mac resolves \(domain): the DNS server has no marina-probe record yet (set up by an older marina). Run `marina up` once to add it.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .bypassed(let profile):
            VStack(alignment: .leading, spacing: 6) {
                Label("Apps on this Mac don't resolve \(domain) names. The DNS server answers, but macOS sends the lookups past /etc/resolver, so curl and browsers get no address. The VM and the pods are unaffected.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if let profile {
                    Text("Cause: an MDM encrypted-DNS profile (\(profile.path)) sends every lookup to \(profile.via) and doesn't exempt \(domain). Only your MDM admin can change it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(adminRequest)
                            .font(.caption)
                            .textSelection(.enabled)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
                        copyButton(adminRequest, help: "Copy the request for your MDM admin")
                    }
                } else {
                    Text("No MDM DNS profile is installed. Look for a VPN or security agent DNS proxy (System Settings › Network › VPN & Filters, or `systemextensionsctl list`), or flush a failure cached before the zone existed:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(Self.flushCommand)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
                        copyButton(Self.flushCommand, help: "Copy the command; it needs sudo, so run it in a terminal")
                    }
                }
            }
        }
    }

    private var adminRequest: String {
        "Please exempt \(domain) in the DNS Settings profile: an OnDemandRules EvaluateConnection rule with DomainAction NeverConnect for Domains [\(domain)]."
    }

    static let flushCommand = "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"

    private func copyButton(_ text: String, help: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
