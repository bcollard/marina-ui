import AppKit
import SwiftUI

/// Log viewer for a pod (one container at a time), a whole workload (every
/// pod and container, prefixed), or a Docker container in the VM. kubectl (or
/// `docker logs` over the guest SSH session) does the fetching; "Follow" re-reads
/// the tail every two seconds rather than holding a `-f` stream open, which
/// keeps one code path and survives pod restarts.
struct PodLogsView: View {
    enum Source: Hashable {
        case pod(WorkloadPod)
        case workload(name: String, kind: String, namespace: String, selector: String)
        case docker(id: String, name: String)
    }

    /// Empty for `.docker`.
    var kubeconfigPath: String = ""
    let source: Source
    /// Required for `.docker`.
    var docker: DockerClient? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var container: String?
    @State private var options = KubeClient.LogOptions()
    @State private var follow = false
    @State private var query = ""
    @State private var onlyMatching = false
    @State private var text = ""
    @State private var error: String?
    @State private var loading = false

    private var title: String {
        switch source {
        case .pod(let p): return p.metadata.name
        case .workload(let name, let kind, _, _): return "\(kind) \(name) — all pods"
        case .docker(_, let name): return name
        }
    }

    private var namespace: String {
        switch source {
        case .pod(let p): return p.namespace
        case .workload(_, _, let ns, _): return ns
        case .docker(let id, _): return "docker " + String(id.prefix(12))
        }
    }

    private var fetchKey: String {
        "\(container ?? "")|\(options.tail)|\(options.timestamps)|\(options.previous)|\(follow)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(namespace).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            controls
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            logBody
        }
        .padding(16)
        .frame(minWidth: 820, idealWidth: 980, minHeight: 520, idealHeight: 640)
        .onAppear {
            if case .pod(let p) = source {
                container = p.spec?.containers?.first?.name ?? p.containerNames.first
            }
        }
        .task(id: fetchKey) {
            await fetch()
            while follow && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await fetch()
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if case .pod(let p) = source, p.containerNames.count > 1 {
                Picker("Container", selection: $container) {
                    ForEach(p.containerNames, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .frame(maxWidth: 220)
            }
            Picker("Lines", selection: $options.tail) {
                ForEach([100, 500, 2000, 10000], id: \.self) { Text("\($0)").tag($0) }
            }
            .frame(maxWidth: 130)
            Toggle("Timestamps", isOn: $options.timestamps)
            if case .pod(let p) = source {
                Toggle("Previous", isOn: $options.previous)
                    .disabled(!p.hasPreviousLogs && !options.previous)
                    .help(p.hasPreviousLogs
                          ? "Logs of the previous, terminated instance of the container (kubectl logs --previous)"
                          : "No container in this pod has restarted")
            }
            Toggle("Follow", isOn: $follow)
                .disabled(options.previous)
                .help("Re-read the tail every 2 seconds")
            Spacer()
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            Toggle("Only matching", isOn: $onlyMatching).disabled(query.isEmpty)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(visibleText, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .help("Copy the visible lines")
            Button { save() } label: { Image(systemName: "square.and.arrow.down") }
                .help("Save the logs to a file")
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }

    private var lines: [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    private var visibleLines: [Substring] {
        guard onlyMatching, !query.isEmpty else { return lines }
        return lines.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var visibleText: String { visibleLines.joined(separator: "\n") }

    private var logBody: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    if text.isEmpty && !loading && error == nil {
                        Text("No log output.").foregroundStyle(.secondary)
                    }
                    Text(rendered)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            .onChange(of: text) { _, _ in
                if follow { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    /// Visible lines with `[pod/…/container]` prefixes dimmed and matches marked.
    private var rendered: AttributedString {
        var out = AttributedString()
        for (i, line) in visibleLines.enumerated() {
            if i > 0 { out += AttributedString("\n") }
            var a = AttributedString(String(line))
            if line.hasPrefix("[pod/"), let close = a.characters.firstIndex(of: "]") {
                let range = a.startIndex..<a.characters.index(after: close)
                a[range].foregroundColor = Color(nsColor: .systemTeal)
            }
            if !query.isEmpty {
                var search = a.startIndex
                while search < a.endIndex,
                      let r = a[search...].range(of: query, options: .caseInsensitive) {
                    a[r].backgroundColor = Color.yellow.opacity(0.45)
                    search = r.upperBound
                }
            }
            out += a
        }
        return out
    }

    private func fetch() async {
        loading = true
        defer { loading = false }
        let kube = KubeClient(kubeconfigPath: kubeconfigPath)
        do {
            switch source {
            case .pod(let p):
                text = try await kube.podLogs(namespace: p.namespace, pod: p.metadata.name,
                                              container: container, options: options)
            case .workload(_, _, let ns, let selector):
                text = try await kube.selectorLogs(namespace: ns, selector: selector, options: options)
            case .docker(let id, _):
                guard let docker else { throw KubeClient.KubeError.decode("the VM is not reachable") }
                text = try await docker.logs(id: id, lines: options.tail, timestamps: options.timestamps)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            if options.previous { text = "" }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title.replacingOccurrences(of: " ", with: "-")).log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
