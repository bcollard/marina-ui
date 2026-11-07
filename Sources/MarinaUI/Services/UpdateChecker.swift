import AppKit
import Foundation
import Observation

/// Looks for new releases of Marina UI and the marina CLI, and updates them
/// through Homebrew.
///
/// Why Homebrew and not Sparkle: both ship as Homebrew casks, so `brew` is
/// already the source of truth for what is installed. Homebrew verifies the
/// download's SHA-256 and Gatekeeper the notarized signature; replacing the app
/// ourselves would bypass both and leave `brew` believing the old version is
/// installed. An install that did not come from Homebrew gets the release page.
///
/// The check is one HEAD request per product (GitHub's releases/latest redirect), at most every
/// `settings.updateCheckDays` (default 14), plus "Check now" (Settings › About,
/// or Marina › Check for Updates…). GitHub's anonymous limit is 60 requests an
/// hour, far above that.
@MainActor
@Observable
final class UpdateChecker {
    enum Product: String, CaseIterable, Identifiable, Sendable {
        case app, cli
        var id: String { rawValue }

        var displayName: String { self == .app ? "Marina UI" : "marina CLI" }
        var repo: String { self == .app ? "bcollard/marina-ui" : "bcollard/marina" }
        var cask: String { self == .app ? "marina-ui" : "marina" }

        /// What to run in a terminal. The CLI is upgraded with the VM stopped:
        /// replacing the binary under a running hostagent makes macOS (amfid)
        /// kill the next `marina` exec.
        var brewCommand: String {
            switch self {
            case .app: return "brew update && brew upgrade --cask marina-ui"
            case .cli: return "marina down && brew update && brew upgrade --cask marina && marina up"
            }
        }
    }

    struct Release: Identifiable, Sendable, Hashable {
        var id: Product { product }
        let product: Product
        let current: String
        let latest: String
        let url: URL
        let notes: String
    }

    /// Newer releases found by the last check, minus skipped versions.
    private(set) var available: [Release] = []
    private(set) var checking = false
    private(set) var lastError: String?
    /// The product being upgraded right now, if any.
    private(set) var updating: Product?
    /// Output of the last update run, shown under the banner.
    private(set) var updateLog = ""
    private(set) var updateFailed = false

    private let settings: AppSettings
    private var scheduleTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
    }

    var lastChecked: Date? { settings.lastUpdateCheck }

    // MARK: - Scheduling

    /// Checks now if the last check is older than the configured interval, then
    /// re-evaluates every hour, since the app can stay open for weeks.
    func startSchedule(cliVersion: @escaping @MainActor () -> String?) {
        scheduleTask?.cancel()
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.settings.checkForUpdates, self.isDue {
                    await self.check(cliVersion: cliVersion())
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private var isDue: Bool {
        guard let last = settings.lastUpdateCheck else { return true }
        return Date().timeIntervalSince(last) >= Double(settings.updateCheckDays) * 24 * 3600
    }

    // MARK: - Checking

    func check(cliVersion: String?) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        var found: [Release] = []
        var errors: [String] = []
        let installed: [Product: String?] = [
            .app: AppAssets.appVersion,
            .cli: cliVersion.map(Self.cleanVersion),
        ]
        for product in Product.allCases {
            guard let current = installed[product] ?? nil, Self.parse(current) != nil else { continue }
            do {
                let latest = try await Self.latestRelease(repo: product.repo)
                let version = Self.cleanVersion(latest.tag)
                if Self.isNewer(version, than: current),
                   settings.skippedVersion(for: product.rawValue) != version {
                    found.append(Release(product: product, current: current, latest: version,
                                         url: latest.url, notes: latest.notes))
                }
            } catch {
                errors.append("\(product.displayName): \(error.localizedDescription)")
            }
        }
        available = found
        lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if errors.isEmpty { settings.lastUpdateCheck = Date() }
    }

    func clearLog() {
        guard updating == nil else { return }
        updateLog = ""
        updateFailed = false
    }

    func skip(_ release: Release) {
        settings.setSkippedVersion(release.latest, for: release.product.rawValue)
        available.removeAll { $0.product == release.product }
    }

    // MARK: - Homebrew

    /// True when the product was installed from its cask (Homebrew keeps a
    /// Caskroom entry per installed cask).
    static func isBrewManaged(_ product: Product) -> Bool {
        ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"].contains {
            FileManager.default.fileExists(atPath: "\($0)/\(product.cask)")
        }
    }

    /// Runs the upgrade. For the app, relaunches it from its (now replaced)
    /// bundle when brew succeeds. For the CLI, stops the VM first and starts it
    /// again afterwards, even when the upgrade fails, so the VM is never left down.
    func update(_ product: Product) async {
        guard updating == nil else { return }
        updating = product
        updateFailed = false
        updateLog = ""
        defer { updating = nil }

        let env = ["HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1"]
        func step(_ title: String, _ exe: String, _ args: [String]) async -> Bool {
            updateLog += "$ \(title)\n"
            do {
                let r = try await ProcessRunner.run(exe, args, environment: env)
                updateLog += r.stdout + r.stderr
                if !r.ok { updateLog += "exited \(r.exitCode)\n" }
                return r.ok
            } catch {
                updateLog += error.localizedDescription + "\n"
                return false
            }
        }

        switch product {
        case .app:
            guard await step("brew update", "brew", ["update", "--quiet"]),
                  await step("brew upgrade --cask marina-ui", "brew", ["upgrade", "--cask", "marina-ui"])
            else {
                updateFailed = true
                updateLog += "\n✗ brew could not upgrade Marina UI.\n"
                return
            }
            updateLog += "\n✓ Upgraded. Relaunching…\n"
            Self.relaunch()
        case .cli:
            guard await step("marina down", "marina", ["down"]) else { updateFailed = true; return }
            var upgraded = await step("brew update", "brew", ["update", "--quiet"])
            if upgraded {
                upgraded = await step("brew upgrade --cask marina", "brew", ["upgrade", "--cask", "marina"])
            }
            let up = await step("marina up", "marina", ["up"])
            updateFailed = !(upgraded && up)
            if updateFailed {
                updateLog += upgraded ? "\n✗ marina up failed — run it in a terminal to see why.\n"
                                      : "\n✗ The upgrade failed; the VM was started again on the old version.\n"
            } else {
                let to = available.first { $0.product == .cli }?.latest ?? "the latest version"
                updateLog += "\n✓ marina CLI updated to \(to); the VM is running again.\n"
                available.removeAll { $0.product == .cli }
            }
        }
    }

    /// Starts a fresh copy of the app from the same path once this one has
    /// exited, then quits. brew has replaced the bundle on disk by now.
    private static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: - GitHub

    private struct LatestRelease: Sendable { let tag: String; let url: URL; let notes: String }

    /// The latest release's tag. First from the web redirect
    /// `github.com/<repo>/releases/latest` → `/releases/tag/<tag>` (a HEAD
    /// request, not counted against the REST API's 60 requests an hour per IP,
    /// which a shared office NAT exhausts easily), then from the API.
    private static func latestRelease(repo: String) async throws -> LatestRelease {
        var head = URLRequest(url: URL(string: "https://github.com/\(repo)/releases/latest")!)
        head.httpMethod = "HEAD"
        head.setValue("MarinaUI/\(AppAssets.appVersion)", forHTTPHeaderField: "User-Agent")
        head.timeoutInterval = 15
        if let (_, response) = try? await URLSession.shared.data(for: head),
           let final = response.url, final.path.contains("/releases/tag/") {
            return LatestRelease(tag: final.lastPathComponent, url: final, notes: "")
        }

        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MarinaUI/\(AppAssets.appVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = (code == 403 || code == 429)
                ? "GitHub's rate limit for this network is reached; the next check retries"
                : "GitHub answered HTTP \(code)"
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        struct R: Decodable { let tag_name: String; let html_url: String; let body: String? }
        let r = try JSONDecoder().decode(R.self, from: data)
        return LatestRelease(tag: r.tag_name, url: URL(string: r.html_url)!, notes: r.body ?? "")
    }

    // MARK: - Versions

    /// "marina 0.3.10" / "v0.3.10" → "0.3.10".
    nonisolated static func cleanVersion(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = v.split(separator: " ").last { v = String(last) }
        if v.hasPrefix("v") { v.removeFirst() }
        return v
    }

    nonisolated static func parse(_ v: String) -> [Int]? {
        let core = v.split(separator: "-").first.map(String.init) ?? v
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parse(a), let y = parse(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p > q }
        }
        return false
    }
}
