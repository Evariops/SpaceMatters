import Foundation
import Observation

/// Drives the Kubernetes storage mode. Loads **progressively** — PVCs first, then
/// the pod tree, then live usage node-by-node — so the screen fills in as data
/// arrives instead of blocking on a single call. Read-only.
@MainActor
@Observable
final class KubernetesController {
    enum State: Equatable { case idle, loading, ready }
    enum Metric: String, CaseIterable, Identifiable {
        case capacity, used
        var id: String { rawValue }
        var label: String { self == .capacity ? "Capacity" : "Used" }
    }

    private(set) var state: State = .idle
    private(set) var contextName = ""
    private(set) var pvcs: [PVCInfo] = []
    private(set) var pods: [PodInfo] = []
    private(set) var pvs: [PVInfo] = []
    private(set) var usageAvailable = false
    /// Live usage progress: nodes scanned so far / total.
    private(set) var nodesScanned = 0
    private(set) var nodesTotal = 0

    /// What's selected in the outline / highlighted in the treemap. `nil` = the
    /// root (whole cluster) → overview, no spotlight.
    enum Selection: Equatable {
        case namespace(String)
        case pod(String)   // "namespace/pod"
        case pvc(String)   // "namespace/name"
    }

    var metric: Metric = .capacity
    var selection: Selection?
    var rootExpanded = true
    var expandedNamespaces: Set<String> = []
    var expandedPods: Set<String> = []

    private var context: String?
    private var loadID = 0

    func size(_ pvc: PVCInfo) -> Int64 { metric == .capacity ? pvc.capacity : (pvc.used ?? 0) }

    var totalCapacity: Int64 { pvcs.reduce(0) { $0 + $1.capacity } }
    var totalUsed: Int64 { pvcs.compactMap(\.used).reduce(0, +) }
    var boundCount: Int { pvcs.filter { $0.phase == "Bound" }.count }
    var pendingCount: Int { pvcs.filter { $0.phase != "Bound" }.count }
    var namespaceCount: Int { Set(pvcs.map(\.namespace)).count }
    var reclaimablePVs: [PVInfo] { pvs.filter(\.reclaimable) }
    var reclaimableBytes: Int64 { reclaimablePVs.reduce(0) { $0 + $1.capacity } }

    // MARK: Lifecycle (progressive)

    func load(context: String) {
        loadID += 1
        let id = loadID
        self.context = context
        contextName = context
        state = .loading
        pvcs = []; pods = []; pvs = []
        selection = nil; expandedNamespaces = []; expandedPods = []
        usageAvailable = false; nodesScanned = 0; nodesTotal = 0
        Task { await streamLoad(context: context, id: id) }
    }

    func refresh() { if let context { load(context: context) } }
    func stop() { loadID += 1 } // invalidate any in-flight load

    private func streamLoad(context: String, id: Int) async {
        // 1) PVCs — show them immediately (capacity bars).
        let pvcList = await Task.detached(priority: .userInitiated) { K8sQueries.pvcs(context: context) }.value
        guard id == loadID else { return }
        pvcs = pvcList
        // Tree starts collapsed; the treemap still shows everything.

        // 2) Pods — regroup the tree under their pods.
        let podList = await Task.detached(priority: .userInitiated) { K8sQueries.pods(context: context) }.value
        guard id == loadID else { return }
        pods = podList

        // 3) PVs (reclaimable).
        let pvList = await Task.detached(priority: .userInitiated) { K8sQueries.pvs(context: context) }.value
        guard id == loadID else { return }
        pvs = pvList

        // 4) Live usage, node by node — bars fill in as each node reports.
        let nodes = await Task.detached(priority: .userInitiated) { K8sQueries.nodeNames(context: context) }.value
        guard id == loadID else { return }
        nodesTotal = nodes.count
        for node in nodes {
            let usage = await Task.detached(priority: .userInitiated) { K8sQueries.nodeUsage(context: context, node: node) }.value
            guard id == loadID else { return }
            nodesScanned += 1
            if !usage.isEmpty {
                usageAvailable = true
                applyUsage(usage)
            }
        }
        state = .ready
    }

    private func applyUsage(_ usage: [String: Int64]) {
        pvcs = pvcs.map { pvc in
            guard let used = usage[pvc.id] else { return pvc }
            var p = pvc; p.used = used; return p
        }
    }

    // MARK: Expansion

    func toggleRoot() { rootExpanded.toggle() }
    func toggleNamespace(_ ns: String) {
        if expandedNamespaces.contains(ns) { expandedNamespaces.remove(ns) } else { expandedNamespaces.insert(ns) }
    }
    func togglePod(_ key: String) {
        if expandedPods.contains(key) { expandedPods.remove(key) } else { expandedPods.insert(key) }
    }

    /// PVCs covered by the current selection (for treemap highlighting).
    func highlightedPVCIDs() -> Set<String> {
        switch selection {
        case .namespace(let ns):
            return Set(pvcs.filter { $0.namespace == ns }.map(\.id))
        case .pod(let key):
            guard let slash = key.firstIndex(of: "/") else { return [] }
            let ns = String(key[..<slash])
            let podName = String(key[key.index(after: slash)...])
            if podName == "(unattached)" {
                let mounted = Set(pods.filter { $0.namespace == ns }.flatMap(\.pvcNames))
                return Set(pvcs.filter { $0.namespace == ns && !mounted.contains($0.name) }.map(\.id))
            }
            guard let pod = pods.first(where: { $0.namespace == ns && $0.name == podName }) else { return [] }
            return Set(pvcs.filter { $0.namespace == ns && pod.pvcNames.contains($0.name) }.map(\.id))
        case .pvc(let id):
            return [id]
        case nil:
            return []
        }
    }

    /// Outline row id to scroll to for a given selection.
    func scrollTarget(for selection: Selection) -> String? {
        switch selection {
        case .namespace(let ns): return "ns:" + ns
        case .pod(let key): return "pod:" + key
        case .pvc(let id):
            return rows().first { if case .pvc(let p) = $0.kind { return p.id == id } else { return false } }?.id
        }
    }

    /// Select a PVC coming from the treemap: expand its namespace and the pod it's
    /// grouped under so the outline row exists, then it can be scrolled to.
    func revealPVC(_ id: String) {
        guard let pvc = pvcs.first(where: { $0.id == id }) else { return }
        rootExpanded = true
        expandedNamespaces.insert(pvc.namespace)
        let pvcByName = Dictionary(
            pvcs.filter { $0.namespace == pvc.namespace }.map { ($0.name, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let mounting = pods
            .filter { $0.namespace == pvc.namespace && $0.pvcNames.contains(pvc.name) }
            .sorted { a, b in
                let ta = a.pvcNames.compactMap { pvcByName[$0] }.reduce(Int64(0)) { $0 + size($1) }
                let tb = b.pvcNames.compactMap { pvcByName[$0] }.reduce(Int64(0)) { $0 + size($1) }
                return ta > tb
            }
        expandedPods.insert(pvc.namespace + "/" + (mounting.first?.name ?? "(unattached)"))
        selection = .pvc(id)
    }

    // MARK: Outline rows (namespace → pod → PVC), flattened for a virtualized List

    struct OutlineRow: Identifiable {
        enum Kind {
            case root(name: String)
            case namespace(name: String)
            case pod(key: String, name: String)
            case pvc(PVCInfo)
        }
        let kind: Kind
        let depth: Int
        let count: Int
        let capacity: Int64
        let used: Int64
        /// Footprint of this row relative to its siblings (0…1) — the whole point:
        /// a visual bar of disk space occupied, like a treemap in list form.
        let sizeFraction: Double
        /// used / capacity (0…1), or nil when live usage isn't known — drives the
        /// consumption pie.
        let usageFraction: Double?
        let colorKey: String
        let isExpanded: Bool
        let id: String
    }

    private func capacity(_ pvcs: [PVCInfo]) -> Int64 { pvcs.reduce(0) { $0 + $1.capacity } }
    private func used(_ pvcs: [PVCInfo]) -> Int64 { pvcs.reduce(0) { $0 + ($1.used ?? 0) } }
    private func usageFrac(cap: Int64, used: Int64) -> Double? {
        (usageAvailable && cap > 0) ? min(1, Double(used) / Double(cap)) : nil
    }

    func rows() -> [OutlineRow] {
        var out: [OutlineRow] = []
        out.append(OutlineRow(
            kind: .root(name: contextName), depth: 0, count: pvcs.count,
            capacity: totalCapacity, used: totalUsed, sizeFraction: 1,
            usageFraction: usageFrac(cap: totalCapacity, used: totalUsed), colorKey: "",
            isExpanded: rootExpanded, id: "root"))
        guard rootExpanded else { return out }

        let byNS = Dictionary(grouping: pvcs, by: \.namespace)
        var podsByNS: [String: [PodInfo]] = [:]
        for pod in pods { podsByNS[pod.namespace, default: []].append(pod) }

        let nsList = byNS.map { (ns: $0.key, pvcs: $0.value, size: $0.value.reduce(Int64(0)) { $0 + size($1) }) }
            .sorted { $0.size > $1.size }
        let maxNs = max(nsList.first?.size ?? 1, 1)

        for group in nsList {
            let nsCap = capacity(group.pvcs), nsUsed = used(group.pvcs)
            let nsExpanded = expandedNamespaces.contains(group.ns)
            out.append(OutlineRow(
                kind: .namespace(name: group.ns), depth: 1, count: group.pvcs.count,
                capacity: nsCap, used: nsUsed, sizeFraction: Double(group.size) / Double(maxNs),
                usageFraction: usageFrac(cap: nsCap, used: nsUsed), colorKey: group.ns,
                isExpanded: nsExpanded, id: "ns:" + group.ns))
            guard nsExpanded else { continue }

            let pvcByName = Dictionary(group.pvcs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            var shown = Set<String>()

            // Build pod groups (biggest first; each PVC under the first pod that mounts it).
            var podRows: [(key: String, name: String, pvcs: [PVCInfo], size: Int64)] = []
            let sortedPods = (podsByNS[group.ns] ?? [])
                .compactMap { pod -> (PodInfo, [PVCInfo], Int64)? in
                    let mounted = pod.pvcNames.compactMap { pvcByName[$0] }
                    return mounted.isEmpty ? nil : (pod, mounted, mounted.reduce(Int64(0)) { $0 + size($1) })
                }
                .sorted { $0.2 > $1.2 }
            for (pod, mounted, _) in sortedPods {
                let fresh = mounted.filter { !shown.contains($0.name) }.sorted { size($0) > size($1) }
                guard !fresh.isEmpty else { continue }
                fresh.forEach { shown.insert($0.name) }
                podRows.append((group.ns + "/" + pod.name, pod.name, fresh, fresh.reduce(Int64(0)) { $0 + size($1) }))
            }
            let unattached = group.pvcs.filter { !shown.contains($0.name) }.sorted { size($0) > size($1) }
            if !unattached.isEmpty {
                podRows.append((group.ns + "/(unattached)", "(unattached)", unattached, unattached.reduce(Int64(0)) { $0 + size($1) }))
            }

            let maxPod = max(podRows.map(\.size).max() ?? 1, 1)
            for pr in podRows {
                let pCap = capacity(pr.pvcs), pUsed = used(pr.pvcs)
                let expanded = expandedPods.contains(pr.key)
                out.append(OutlineRow(
                    kind: .pod(key: pr.key, name: pr.name), depth: 2, count: pr.pvcs.count,
                    capacity: pCap, used: pUsed, sizeFraction: Double(pr.size) / Double(maxPod),
                    usageFraction: usageFrac(cap: pCap, used: pUsed), colorKey: group.ns,
                    isExpanded: expanded, id: "pod:" + pr.key))
                guard expanded else { continue }
                let maxPvc = max(pr.pvcs.map { size($0) }.max() ?? 1, 1)
                for pvc in pr.pvcs {
                    out.append(OutlineRow(
                        kind: .pvc(pvc), depth: 3, count: 0,
                        capacity: pvc.capacity, used: pvc.used ?? 0, sizeFraction: Double(size(pvc)) / Double(maxPvc),
                        usageFraction: pvc.usageFraction, colorKey: group.ns,
                        isExpanded: false, id: "pvc:" + pr.key + ":" + pvc.id))
                }
            }
        }
        return out
    }

    // MARK: Treemap groups (namespace → unique PVCs)

    struct TreemapGroup: Identifiable {
        let name: String
        let pvcs: [PVCInfo]
        let total: Int64
        var id: String { name }
    }

    func treemapGroups() -> [TreemapGroup] {
        Dictionary(grouping: pvcs, by: \.namespace).map { ns, items in
            let positive = items.filter { size($0) > 0 }.sorted { size($0) > size($1) }
            return TreemapGroup(name: ns, pvcs: positive, total: positive.reduce(Int64(0)) { $0 + size($1) })
        }
        .filter { $0.total > 0 }
        .sorted { $0.total > $1.total }
    }
}
