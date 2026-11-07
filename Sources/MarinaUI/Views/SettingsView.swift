import SwiftUI

/// The app's preferences window (⌘,). Four tabs: what's visible, how often the
/// various background pollers refresh, the health of the marina stack and of
/// this app bundle, and the versions this app is talking to.
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        TabView {
            Form {
                Section {
                    Toggle("Console log panel", isOn: $settings.showConsoleLog)
                    Text("Pins an aggregated, timestamped log of every action to the bottom of the main view.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Registry / pull-through mirrors", isOn: $settings.showMirrors)
                    Text("Show the mirrors section in the sidebar and overview.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("VM stats & graphs", isOn: $settings.showVMStats)
                    Text("Show the VM's load and memory rows plus the CPU/memory charts. When off, the VM is not polled over SSH.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Docker containers", isOn: $settings.showContainers)
                    Text("Show the containers you run in the VM's Docker — everything except marina's own kind nodes, registry mirrors and local DNS server. When off, the VM's Docker is not queried.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Visibility", systemImage: "eye") }

            Form {
                Section("Refresh intervals") {
                    Stepper(
                        "Cluster list: \(Int(settings.clusterRefreshSeconds)) s",
                        value: $settings.clusterRefreshSeconds, in: 2...60, step: 1
                    )
                    Stepper(
                        "VM stats: \(Int(settings.vmPollSeconds)) s",
                        value: $settings.vmPollSeconds, in: 2...60, step: 1
                    )
                    Stepper(
                        "Cluster metrics: \(Int(settings.metricsPollSeconds)) s",
                        value: $settings.metricsPollSeconds, in: 5...120, step: 5
                    )
                }
                Section {
                    Text("Changes take effect on the next poll cycle. Shorter intervals feel more live but do more work (SSH round-trips, kubectl calls).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Refresh", systemImage: "arrow.clockwise") }

            DiagnosticsTabView(model: model)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }

            AboutTab(model: model)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        // Explicit height: left to size itself the TabView settles on the
        // shortest tab and clips the taller ones (Visibility's fourth toggle,
        // the Diagnostics checks) behind a scroll bar the user won't look for.
        .frame(width: 520, height: 620)
    }
}

/// Versions of everything in the stack: this app, the marina CLI it drives, the
/// Kubernetes the kind nodes run, and the guest VM's Linux.
private struct AboutTab: View {
    @Bindable var model: AppModel

    var body: some View {
        // No app-logo header here: the extra height pushed the form past the
        // window and the header scrolled up behind the translucent tab bar.
        Form {
            Section("Versions") {
                row("Marina UI", AppAssets.appVersion, icon: "macwindow")
                row(
                    "marina CLI",
                    model.marinaVersion?
                        .replacingOccurrences(of: "marina ", with: ""),
                    icon: "terminal"
                )
                row(
                    "Kubernetes (kind nodes)",
                    model.kubeNodeVersionSummary?.text,
                    icon: "circle.grid.3x3",
                    help: model.kubeNodeVersionSummary?.help
                )
            }

            UpdatesSection(model: model)

            Section("Guest VM") {
                row("Distribution", model.guestStats?.osName, icon: "opticaldiscdrive")
                row("Kernel", model.guestStats?.kernel, icon: "cpu")
            }

            Section {
                Text("Guest values are read over SSH and refresh with the VM; they show “—” while the VM is stopped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // The VM poll loop backfills these, but it's off when "VM stats" is
        // disabled — fetch on open so this tab is never stuck on "—".
        .task { await model.ensureGuestOSInfo() }
    }

    private func row(_ label: String, _ value: String?, icon: String, help: String? = nil) -> some View {
        LabeledContent {
            Text(value ?? "—")
                .font(.callout.monospacedDigit())
                .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
        } label: {
            Label(label, systemImage: icon)
        }
        .help(help ?? "")
    }
}
