import Foundation

/// A controller object from `kubectl get deploy,sts,ds,job,cronjob,rs -A -o json`.
/// One type for every kind: the list mixes them, and the fields we show are a
/// small union. ReplicaSets are fetched only to resolve Deployment → pod
/// ownership and are not listed.
struct Workload: Decodable, Sendable, Hashable, Identifiable {
    var id: String { "\(kind)/\(metadata.namespace ?? "")/\(metadata.name)" }
    let kind: String
    let metadata: WorkloadMeta
    let spec: Spec?
    let status: Status?

    struct Spec: Decodable, Sendable, Hashable {
        let replicas: Int?
        let completions: Int?
        let schedule: String?
        let suspend: Bool?
        let selector: Selector?

        struct Selector: Decodable, Sendable, Hashable {
            let matchLabels: [String: String]?
        }
    }

    struct Status: Decodable, Sendable, Hashable {
        // Deployment / StatefulSet / ReplicaSet
        let replicas: Int?
        let readyReplicas: Int?
        let updatedReplicas: Int?
        // DaemonSet
        let desiredNumberScheduled: Int?
        let numberReady: Int?
        // Job: `active` is a count; CronJob: `active` is a list of Job refs.
        let active: Int
        let succeeded: Int?
        let failed: Int?
        let lastScheduleTime: String?

        enum CodingKeys: String, CodingKey {
            case replicas, readyReplicas, updatedReplicas, desiredNumberScheduled, numberReady
            case active, succeeded, failed, lastScheduleTime
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            replicas = try c.decodeIfPresent(Int.self, forKey: .replicas)
            readyReplicas = try c.decodeIfPresent(Int.self, forKey: .readyReplicas)
            updatedReplicas = try c.decodeIfPresent(Int.self, forKey: .updatedReplicas)
            desiredNumberScheduled = try c.decodeIfPresent(Int.self, forKey: .desiredNumberScheduled)
            numberReady = try c.decodeIfPresent(Int.self, forKey: .numberReady)
            succeeded = try c.decodeIfPresent(Int.self, forKey: .succeeded)
            failed = try c.decodeIfPresent(Int.self, forKey: .failed)
            lastScheduleTime = try c.decodeIfPresent(String.self, forKey: .lastScheduleTime)
            if let n = try? c.decodeIfPresent(Int.self, forKey: .active) {
                active = n
            } else if let refs = try? c.decodeIfPresent([IgnoredRef].self, forKey: .active) {
                active = refs.count
            } else {
                active = 0
            }
        }
        private struct IgnoredRef: Decodable {}
    }

    enum Health: Sendable { case ok, progressing, failed, idle }

    /// "ready/desired" (or the kind's equivalent) and an overall health.
    var readiness: (text: String, health: Health) {
        switch kind {
        case "Deployment", "StatefulSet":
            let desired = spec?.replicas ?? 1
            let ready = status?.readyReplicas ?? 0
            if desired == 0 { return ("0/0", .idle) }
            return ("\(ready)/\(desired)", ready >= desired ? .ok : .progressing)
        case "DaemonSet":
            let desired = status?.desiredNumberScheduled ?? 0
            let ready = status?.numberReady ?? 0
            return ("\(ready)/\(desired)", ready >= desired ? .ok : .progressing)
        case "Job":
            let want = spec?.completions ?? 1
            let done = status?.succeeded ?? 0
            if (status?.failed ?? 0) > 0 && done < want { return ("\(done)/\(want)", .failed) }
            return ("\(done)/\(want)", done >= want ? .ok : .progressing)
        case "CronJob":
            if spec?.suspend == true { return ("suspended", .idle) }
            let a = status?.active ?? 0
            return (a > 0 ? "\(a) active" : (spec?.schedule ?? ""), a > 0 ? .progressing : .ok)
        default:
            return ("", .idle)
        }
    }

    /// Kinds that `kubectl rollout restart` supports.
    var restartable: Bool { ["Deployment", "StatefulSet", "DaemonSet"].contains(kind) }

    /// `-l` selector for the pods this workload manages, when it has one.
    var podSelector: String? {
        guard let m = spec?.selector?.matchLabels, !m.isEmpty else { return nil }
        return m.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    static let listedKinds = ["Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"]
}

struct WorkloadMeta: Decodable, Sendable, Hashable {
    let name: String
    let namespace: String?
    let uid: String?
    let creationTimestamp: String?
    let ownerReferences: [OwnerRef]?
    let labels: [String: String]?

    struct OwnerRef: Decodable, Sendable, Hashable {
        let kind: String
        let name: String
        let uid: String?
        let controller: Bool?
    }

    var controllerRef: OwnerRef? {
        ownerReferences?.first { $0.controller == true } ?? ownerReferences?.first
    }

    var createdAt: Date? {
        creationTimestamp.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}

/// A pod with what the workloads view and the log viewer need.
struct WorkloadPod: Decodable, Sendable, Hashable, Identifiable {
    var id: String { "\(metadata.namespace ?? "")/\(metadata.name)" }
    let metadata: WorkloadMeta
    let spec: Spec?
    let status: Status?

    struct Spec: Decodable, Sendable, Hashable {
        let containers: [Named]?
        let initContainers: [Named]?
        let ephemeralContainers: [Named]?
        let nodeName: String?
    }
    struct Named: Decodable, Sendable, Hashable { let name: String }

    struct Status: Decodable, Sendable, Hashable {
        let phase: String?
        let reason: String?
        let podIP: String?
        let containerStatuses: [ContainerStatus]?
        let initContainerStatuses: [ContainerStatus]?
    }

    struct ContainerStatus: Decodable, Sendable, Hashable {
        let name: String
        let ready: Bool?
        let restartCount: Int?
        let state: State?
        let lastState: State?

        struct State: Decodable, Sendable, Hashable {
            let waiting: Reason?
            let terminated: Reason?
            let running: Running?
        }
        struct Reason: Decodable, Sendable, Hashable { let reason: String? }
        struct Running: Decodable, Sendable, Hashable { let startedAt: String? }
    }

    var namespace: String { metadata.namespace ?? "default" }

    /// Containers in the order `kubectl logs -c` accepts them: init, app, ephemeral.
    var containerNames: [String] {
        (spec?.initContainers ?? []).map(\.name)
            + (spec?.containers ?? []).map(\.name)
            + (spec?.ephemeralContainers ?? []).map(\.name)
    }

    var restarts: Int {
        (status?.containerStatuses ?? []).reduce(0) { $0 + ($1.restartCount ?? 0) }
    }

    /// True when some container has terminated before, i.e. `--previous` has logs.
    var hasPreviousLogs: Bool {
        (status?.containerStatuses ?? []).contains { $0.lastState?.terminated != nil }
    }

    var readyText: String {
        let cs = status?.containerStatuses ?? []
        return "\(cs.filter { $0.ready == true }.count)/\(spec?.containers?.count ?? cs.count)"
    }

    /// What `kubectl get pods` shows in STATUS: a container's waiting or
    /// terminated reason (CrashLoopBackOff, ImagePullBackOff…) beats the phase.
    var displayStatus: String {
        for c in status?.containerStatuses ?? [] {
            if let r = c.state?.waiting?.reason { return r }
            if let r = c.state?.terminated?.reason, status?.phase == "Running" { return r }
        }
        return status?.reason ?? status?.phase ?? "Unknown"
    }

    var healthy: Bool {
        let s = displayStatus
        return s == "Running" || s == "Succeeded" || s == "Completed"
    }
}

/// Workloads with their pods, owner chains resolved.
struct WorkloadSnapshot: Sendable {
    var workloads: [Workload] = []
    /// Workload id → its pods (Deployment pods via their ReplicaSet,
    /// CronJob pods via their Job).
    var podsByWorkload: [String: [WorkloadPod]] = [:]
    /// Pods with no listed controller (bare pods, static pods).
    var orphanPods: [WorkloadPod] = []

    static func build(objects: [Workload], pods: [WorkloadPod]) -> WorkloadSnapshot {
        var byUID: [String: Workload] = [:]
        var byKey: [String: Workload] = [:]
        for o in objects {
            if let uid = o.metadata.uid { byUID[uid] = o }
            byKey["\(o.kind)/\(o.metadata.namespace ?? "")/\(o.metadata.name)"] = o
        }
        func lookup(_ ref: WorkloadMeta.OwnerRef, ns: String?) -> Workload? {
            if let uid = ref.uid, let w = byUID[uid] { return w }
            return byKey["\(ref.kind)/\(ns ?? "")/\(ref.name)"]
        }
        /// Walk ReplicaSet → Deployment and Job → CronJob up to a listed kind.
        func topLevel(_ meta: WorkloadMeta) -> Workload? {
            var current = meta
            for _ in 0..<4 {
                guard let ref = current.controllerRef, let owner = lookup(ref, ns: current.namespace) else {
                    return nil
                }
                if owner.kind == "Job",
                   let parentRef = owner.metadata.controllerRef, parentRef.kind == "CronJob",
                   let parent = lookup(parentRef, ns: owner.metadata.namespace) {
                    return parent
                }
                if Workload.listedKinds.contains(owner.kind) { return owner }
                current = owner.metadata
            }
            return nil
        }

        var snap = WorkloadSnapshot()
        snap.workloads = objects
            .filter { Workload.listedKinds.contains($0.kind) }
            // A Job a CronJob owns shows under the CronJob, not on its own.
            .filter { !($0.kind == "Job" && $0.metadata.controllerRef?.kind == "CronJob") }
        for p in pods {
            if let w = topLevel(p.metadata) {
                snap.podsByWorkload[w.id, default: []].append(p)
            } else {
                snap.orphanPods.append(p)
            }
        }
        return snap
    }
}
