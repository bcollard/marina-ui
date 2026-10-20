import Foundation

/// Executes commands in the guest VM by shelling out to `ssh -F <instance>/ssh.config`.
/// Reuses marina's existing ControlMaster socket so calls are cheap and require no
/// extra credentials beyond what marina already wrote to disk.
struct GuestSSH: Sendable {
    let endpoint: SSHEndpoint

    enum GuestError: Error, LocalizedError {
        case command(Int32, String)
        var errorDescription: String? {
            if case .command(let c, let s) = self { return "ssh exited \(c): \(s)" }
            return nil
        }
    }

    /// Run a one-shot command and return stdout. Throws on non-zero exit.
    func run(_ command: String, timeout: TimeInterval = 10) async throws -> String {
        // Use BatchMode + ConnectTimeout to fail fast if the VM is down.
        let args = [
            "-F", endpoint.configPath,
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(Int(timeout))",
            endpoint.hostAlias,
            command,
        ]
        let result = try await ProcessRunner.run("ssh", args)
        guard result.ok else {
            throw GuestError.command(result.exitCode, result.stderr)
        }
        return result.stdout
    }

    /// Probe lima0 IPv4 address. Returns nil if the interface isn't up or VM isn't reachable.
    func lima0IP() async -> String? {
        guard let out = try? await run(
            "ip -4 -o addr show lima0 2>/dev/null | awk '{print $4}' | cut -d/ -f1"
        ) else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One filesystem's usage, as reported by `df -k`.
    struct DiskUsage: Sendable, Hashable {
        let device: String
        let totalKB: Int
        let usedKB: Int
        let availKB: Int
    }

    /// Snapshot of basic guest stats. All fields are best-effort.
    struct GuestStats: Sendable, Hashable {
        let uptime: String?
        let loadAvg: String?
        let memTotalKB: Int?
        let memAvailableKB: Int?
        let kernel: String?
        /// `PRETTY_NAME` from /etc/os-release, e.g. "Ubuntu 26.04 LTS".
        let osName: String?
        /// The VM's root disk (`/`).
        let rootDisk: DiskUsage?
        /// marina's persistent image-cache disk, mounted at `/var/lib/containerd`
        /// (see `additionalDisks` in lima.yaml) — everything `docker pull`/`build`
        /// writes lives here, separately from the root disk. `nil` when it isn't
        /// actually a distinct filesystem (older marina without the split, or the
        /// mount hasn't landed yet), so the UI doesn't show two identical bars.
        let imageDisk: DiskUsage?
    }

    /// Single-shot reading of CPU counters and memory totals for time-series
    /// graphing. One SSH round-trip; rides the existing ControlMaster socket.
    func rawSample() async -> GuestRawSample? {
        guard let out = try? await run(
            "head -1 /proc/stat; echo '---'; head -3 /proc/meminfo; echo '---'; cat /proc/loadavg"
        ) else { return nil }
        let parts = out.components(separatedBy: "---")
        guard parts.count >= 2 else { return nil }
        guard let (total, idle) = parseProcStat(parts[0]) else { return nil }
        let (totalKB, availKB) = parseMemInfo(parts[1])
        guard let totalKB, let availKB else { return nil }
        let loadAvg = parts.count >= 3
            ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        return GuestRawSample(
            timestamp: Date(),
            cpuTotalTicks: total,
            cpuIdleTicks: idle,
            memTotalKB: totalKB,
            memAvailableKB: availKB,
            loadAvg: (loadAvg?.isEmpty ?? true) ? nil : loadAvg
        )
    }

    /// Parse `/proc/stat`'s first line: "cpu  user nice system idle iowait …".
    /// Returns (totalTicks, idleTicks) where idle includes iowait per the
    /// convention used by `top`, `mpstat`, etc.
    private func parseProcStat(_ block: String) -> (UInt64, UInt64)? {
        for line in block.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first == "cpu", fields.count >= 6 else { continue }
            let nums = fields.dropFirst().compactMap { UInt64($0) }
            guard nums.count >= 5 else { return nil }
            let total = nums.reduce(0, +)
            let idle = nums[3] + nums[4]  // idle + iowait
            return (total, idle)
        }
        return nil
    }

    private func parseMemInfo(_ block: String) -> (Int?, Int?) {
        var total: Int?
        var avail: Int?
        for line in block.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("MemTotal:") { total = parseKB(String(line)) }
            else if line.hasPrefix("MemAvailable:") { avail = parseKB(String(line)) }
        }
        return (total, avail)
    }

    /// Kernel release and distro name. Split out from `stats()` so the poll loop
    /// can backfill them when the full stats call came back empty.
    func osInfo() async -> (kernel: String, osName: String?)? {
        guard let out = try? await run(Self.osCommand) else { return nil }
        let lines = Self.nonEmptyLines(out)
        guard let kernel = lines.first else { return nil }
        return (kernel, lines.count >= 2 ? lines[1] : nil)
    }

    /// Root and image-cache disk usage. Split out from `stats()` for the same
    /// backfill reason as `osInfo()`.
    func diskUsage() async -> (root: DiskUsage?, image: DiskUsage?)? {
        guard let out = try? await run(Self.dfCommand) else { return nil }
        let disks = parseDiskUsage(out)
        return disks.root == nil ? nil : disks
    }

    private static let dfCommand =
        "df -k --output=source,size,used,avail / /var/lib/containerd 2>/dev/null || true"

    /// `uname -r` then the unquoted PRETTY_NAME from /etc/os-release.
    private static let osCommand =
        #"uname -r; sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release"#

    private static func nonEmptyLines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func stats() async -> GuestStats {
        // One round-trip, sections separated by `---`. This used to be four
        // concurrent `run()` calls, but concurrent ssh invocations race each
        // other while the ControlMaster socket is still being set up: a loser
        // fails, its `try?` yields nil, and — since the 5 s sample loop only
        // carries the previous value forward — that field stays nil for the
        // lifetime of the app.
        let empty = GuestStats(
            uptime: nil, loadAvg: nil, memTotalKB: nil,
            memAvailableKB: nil, kernel: nil, osName: nil,
            rootDisk: nil, imageDisk: nil
        )
        guard let out = try? await run(
            "uptime -p; echo ---; cat /proc/loadavg; echo ---; head -3 /proc/meminfo; echo ---; "
            + Self.osCommand
            + "; echo ---; " + Self.dfCommand
        ) else { return empty }

        let sections = out.components(separatedBy: "---")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func section(_ i: Int) -> String? {
            guard i < sections.count, !sections[i].isEmpty else { return nil }
            return sections[i]
        }

        let (memTotal, memAvail) = parseMemInfo(section(2) ?? "")
        let osLines = Self.nonEmptyLines(section(3) ?? "")
        let (rootDisk, imageDisk) = parseDiskUsage(section(4) ?? "")
        return GuestStats(
            uptime: section(0),
            loadAvg: section(1),
            memTotalKB: memTotal,
            memAvailableKB: memAvail,
            kernel: osLines.first,
            osName: osLines.count >= 2 ? osLines[1] : nil,
            rootDisk: rootDisk,
            imageDisk: imageDisk
        )
    }

    /// `df -k --output=source,size,used,avail / /var/lib/containerd`: a header
    /// line, then one data line per path in the order passed. The image disk
    /// is only reported when its device differs from the root's — otherwise
    /// `/var/lib/containerd` is just a directory on the root filesystem (older
    /// marina without the `additionalDisks` split), and showing two identical
    /// bars would be misleading rather than informative.
    private func parseDiskUsage(_ block: String) -> (root: DiskUsage?, image: DiskUsage?) {
        func parse(_ line: String) -> DiskUsage? {
            let f = line.split(whereSeparator: \.isWhitespace)
            guard f.count >= 4,
                  let total = Int(f[1]), let used = Int(f[2]), let avail = Int(f[3])
            else { return nil }
            return DiskUsage(device: String(f[0]), totalKB: total, usedKB: used, availKB: avail)
        }
        let rows = Self.nonEmptyLines(block).dropFirst().compactMap(parse)
        guard let root = rows.first else { return (nil, nil) }
        guard rows.count >= 2, rows[1].device != root.device else { return (root, nil) }
        return (root, rows[1])
    }

    private func parseKB(_ line: String) -> Int? {
        // "MemTotal:       20480000 kB"
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }
}
