import SwiftUI

/// Modal sheet for `marina fleet create`: a fleet name plus the names of the
/// clusters that belong to it. Everything else takes marina's defaults.
struct NewFleetSheet: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var fleetName = ""
    @State private var clusterText = ""

    /// RFC 1123 label: what marina accepts for cluster and fleet names.
    private static let nameRE = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/

    private var trimmedFleet: String {
        fleetName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cluster names split on commas, spaces and newlines, duplicates dropped.
    private var clusterNames: [String] {
        var seen = Set<String>()
        return clusterText
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
            .filter { seen.insert($0).inserted }
    }

    private var validationError: String? {
        if trimmedFleet.isEmpty || clusterNames.isEmpty { return nil }
        if trimmedFleet.wholeMatch(of: Self.nameRE) == nil {
            return "Fleet name: lowercase letters, digits and dashes."
        }
        if let bad = clusterNames.first(where: { $0.wholeMatch(of: Self.nameRE) == nil }) {
            return "Invalid cluster name \"\(bad)\": lowercase letters, digits and dashes."
        }
        if clusterNames.contains(trimmedFleet) {
            return "A fleet and a cluster cannot share a name."
        }
        if model.clusters.contains(where: { $0.name == trimmedFleet }) {
            return "A cluster named \"\(trimmedFleet)\" already exists."
        }
        return nil
    }

    private var canCreate: Bool {
        !trimmedFleet.isEmpty && !clusterNames.isEmpty && validationError == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create fleet").font(.title3.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text("Fleet name").font(.callout.weight(.medium))
                TextField("fleet name", text: $fleetName)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Clusters").font(.callout.weight(.medium))
                // TextEditor, not a vertical TextField: in a sheet with a
                // default-action button, Return in a TextField submits.
                TextEditor(text: $clusterText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 90)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if clusterText.isEmpty {
                            Text("dev\nstaging\nprod")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .allowsHitTesting(false)
                        }
                    }
                Text("Separate names with commas, spaces or new lines. Existing clusters join the fleet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create") {
                    let fleet = trimmedFleet
                    let clusters = clusterNames
                    isPresented = false
                    Task { await model.createFleet(named: fleet, clusters: clusters) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
