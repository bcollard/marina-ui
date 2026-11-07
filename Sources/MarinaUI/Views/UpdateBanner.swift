import AppKit
import SwiftUI

/// "A new version is available" card at the top of the overview, one per
/// product with a newer release. Hidden when there is nothing to offer.
struct UpdateBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        let updates = model.updates
        if !updates.available.isEmpty || updates.updating != nil || !updates.updateLog.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(updates.available) { release in
                    UpdateCard(model: model, release: release)
                }
                if !updates.updateLog.isEmpty {
                    LogConsoleView(
                        title: updates.updating != nil ? "Updating…" : (updates.updateFailed ? "Update failed" : "Update log"),
                        text: updates.updateLog,
                        maxHeight: 180,
                        followTail: true
                    )
                    if updates.updating == nil {
                        Button("Dismiss") { updates.clearLog() }
                            .controlSize(.small)
                    }
                }
            }
            // The CLI version, VM state and clusters changed under us.
            .onChange(of: updates.updating) { old, new in
                if old == .cli, new == nil { Task { await model.refreshAll() } }
            }
        }
    }
}

private struct UpdateCard: View {
    @Bindable var model: AppModel
    let release: UpdateChecker.Release
    @State private var confirmCLI = false
    @State private var copied = false

    private var brewManaged: Bool { UpdateChecker.isBrewManaged(release.product) }

    var body: some View {
        let updating = model.updates.updating
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("\(release.product.displayName) \(release.latest) is available").font(.headline)
                    Text("you have \(release.current)").font(.caption).foregroundStyle(.secondary)
                }
                if brewManaged {
                    HStack(spacing: 6) {
                        Text(release.product.brewCommand)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(release.product.brewCommand, forType: .string)
                            copied = true
                        }
                        .controlSize(.small)
                    }
                    if release.product == .cli {
                        Text("Stops the VM while the binary is replaced; clusters come back with `marina up`.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not installed with Homebrew — download it from the release page.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if brewManaged {
                        Button {
                            if release.product == .cli { confirmCLI = true }
                            else { Task { await model.updates.update(.app) } }
                        } label: {
                            if updating == release.product {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Update now")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(updating != nil || model.inFlightAction != nil)
                        .help(release.product == .app
                              ? "Runs brew upgrade --cask marina-ui, then relaunches Marina UI"
                              : "Runs marina down, brew upgrade --cask marina, marina up")
                    }
                    Link("Release notes", destination: release.url)
                    Button("Skip this version") { model.updates.skip(release) }
                        .buttonStyle(.link)
                        .disabled(updating != nil)
                }
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.3)))
        .confirmationDialog("Update the marina CLI to \(release.latest)?", isPresented: $confirmCLI) {
            Button("Stop VM, Update, Start VM") { Task { await model.updates.update(.cli) } }
        } message: {
            Text("Runs marina down, brew upgrade --cask marina, then marina up. Clusters stop for the minute or two this takes and come back with the VM.")
        }
    }
}

/// Settings › About: the automatic check toggle, last check, Check now.
struct UpdatesSection: View {
    @Bindable var model: AppModel
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let updates = model.updates
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $settings.checkForUpdates)
            Picker("Check every", selection: $settings.updateCheckDays) {
                Text("Day").tag(1)
                Text("Week").tag(7)
                Text("Two weeks").tag(14)
                Text("Month").tag(30)
            }
            .disabled(!settings.checkForUpdates)
            HStack {
                if let last = updates.lastChecked {
                    Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Never checked").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if updates.checking { ProgressView().controlSize(.small) }
                Button("Check now") { Task { await updates.check(cliVersion: model.marinaVersion) } }
                    .disabled(updates.checking)
            }
            if !updates.checking, updates.lastChecked != nil, updates.available.isEmpty, updates.lastError == nil {
                Label("Marina UI and the marina CLI are up to date", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            ForEach(updates.available) { r in
                Label("\(r.product.displayName) \(r.latest) is available — see the overview", systemImage: "arrow.down.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            if let err = updates.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("The check asks GitHub for the latest release of bcollard/marina-ui and bcollard/marina. Updates go through Homebrew, which verifies the download.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
