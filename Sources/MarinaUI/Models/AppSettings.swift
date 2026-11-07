import Foundation
import Observation

/// User-facing preferences, persisted to `UserDefaults` and shared between the
/// views (via the SwiftUI environment) and `AppModel` (which reads the poll
/// cadences on each loop iteration). Backed by `@Observable` so toggles and
/// steppers in the Settings window update the UI live.
@MainActor
@Observable
final class AppSettings {
    // MARK: Visibility

    /// Show the aggregated console-log panel pinned to the bottom of the detail
    /// area. Off by default — the per-view "Last action" cards cover most needs.
    var showConsoleLog: Bool { didSet { store.set(showConsoleLog, forKey: Keys.showConsoleLog) } }

    /// Show the registry / pull-through mirror sections in the sidebar and
    /// overview. Users without mirrors can hide the clutter.
    var showMirrors: Bool { didSet { store.set(showMirrors, forKey: Keys.showMirrors) } }

    /// Show the VM CPU/memory stats and graphs (sidebar Load/Used rows +
    /// the VM resources charts). When off, VM polling over SSH is also paused.
    var showVMStats: Bool { didSet { store.set(showVMStats, forKey: Keys.showVMStats) } }

    /// Show the containers running in the guest VM that marina does not manage
    /// — everything except the kind nodes, the pull-through registry mirrors
    /// and the local DNS containers, which already have their own place in the UI. Off by
    /// default: a stock marina VM has none, so the section would just be empty.
    var showContainers: Bool { didSet { store.set(showContainers, forKey: Keys.showContainers) } }

    // MARK: Refresh cadences (seconds)

    /// How often we poll for out-of-band cluster list changes (create/delete
    /// via the CLI, VM up/down). Maps to `AppModel`'s state poll loop.
    var clusterRefreshSeconds: Double { didSet { store.set(clusterRefreshSeconds, forKey: Keys.clusterRefreshSeconds) } }

    /// How often we sample VM CPU%/memory/load over SSH.
    var vmPollSeconds: Double { didSet { store.set(vmPollSeconds, forKey: Keys.vmPollSeconds) } }

    /// How often we poll cluster metrics (node + pod CPU/memory) via metrics-server.
    var metricsPollSeconds: Double { didSet { store.set(metricsPollSeconds, forKey: Keys.metricsPollSeconds) } }

    // MARK: Updates

    /// Look for new Marina UI / marina CLI releases every 14 days (one GitHub
    /// API call per product). "Check now" works either way.
    var checkForUpdates: Bool { didSet { store.set(checkForUpdates, forKey: Keys.checkForUpdates) } }

    /// When the last successful update check ran.
    var lastUpdateCheck: Date? {
        get { store.object(forKey: Keys.lastUpdateCheck) as? Date }
        set { store.set(newValue, forKey: Keys.lastUpdateCheck) }
    }

    /// "Skip this version": the release stops being offered until a newer one.
    func skippedVersion(for product: String) -> String? {
        store.string(forKey: Keys.skippedVersionPrefix + product)
    }
    func setSkippedVersion(_ v: String, for product: String) {
        store.set(v, forKey: Keys.skippedVersionPrefix + product)
    }

    // MARK: Durations for the poll loops (clamped to safe minimums)

    var clusterRefreshInterval: Duration { .seconds(max(2, clusterRefreshSeconds)) }
    var vmPollInterval: Duration { .seconds(max(2, vmPollSeconds)) }
    var metricsPollInterval: Duration { .seconds(max(2, metricsPollSeconds)) }

    // MARK: Init

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        store.register(defaults: [
            Keys.showConsoleLog: false,
            Keys.showMirrors: true,
            Keys.showVMStats: true,
            Keys.showContainers: false,
            Keys.clusterRefreshSeconds: 6.0,
            Keys.vmPollSeconds: 5.0,
            Keys.metricsPollSeconds: 15.0,
            Keys.checkForUpdates: true,
        ])
        showConsoleLog = store.bool(forKey: Keys.showConsoleLog)
        showMirrors = store.bool(forKey: Keys.showMirrors)
        showVMStats = store.bool(forKey: Keys.showVMStats)
        showContainers = store.bool(forKey: Keys.showContainers)
        clusterRefreshSeconds = store.double(forKey: Keys.clusterRefreshSeconds)
        vmPollSeconds = store.double(forKey: Keys.vmPollSeconds)
        metricsPollSeconds = store.double(forKey: Keys.metricsPollSeconds)
        checkForUpdates = store.bool(forKey: Keys.checkForUpdates)
    }

    private enum Keys {
        static let showConsoleLog = "settings.showConsoleLog"
        static let showMirrors = "settings.showMirrors"
        static let showVMStats = "settings.showVMStats"
        static let showContainers = "settings.showContainers"
        static let clusterRefreshSeconds = "settings.clusterRefreshSeconds"
        static let vmPollSeconds = "settings.vmPollSeconds"
        static let metricsPollSeconds = "settings.metricsPollSeconds"
        static let checkForUpdates = "settings.checkForUpdates"
        static let lastUpdateCheck = "updates.lastCheck"
        static let skippedVersionPrefix = "updates.skipped."
    }
}
