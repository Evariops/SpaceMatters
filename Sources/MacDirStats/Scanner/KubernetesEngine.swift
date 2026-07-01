import Foundation

struct K8sContext: Identifiable {
    let name: String
    let isCurrent: Bool
    var id: String { name }
}

struct PVCInfo: Identifiable {
    let namespace: String
    let name: String
    let capacity: Int64        // provisioned (status.capacity, else requested)
    var used: Int64?           // live, from kubelet stats (nil if unavailable)
    let accessModes: [String]
    let storageClass: String
    let phase: String          // Bound / Pending / Lost
    let volumeName: String?

    var id: String { namespace + "/" + name }
    var usageFraction: Double? {
        guard let used, capacity > 0 else { return nil }
        return min(1, Double(used) / Double(capacity))
    }
    /// Compact access-mode label: RWO / RWX / ROX.
    var accessShort: String {
        accessModes.map {
            switch $0 {
            case "ReadWriteOnce": return "RWO"
            case "ReadWriteMany": return "RWX"
            case "ReadOnlyMany": return "ROX"
            case "ReadWriteOncePod": return "RWOP"
            default: return $0
            }
        }.joined(separator: "/")
    }
}

struct PVInfo: Identifiable {
    let name: String
    let capacity: Int64
    let status: String         // Bound / Available / Released / Failed
    let storageClass: String
    let reclaimPolicy: String
    let claim: String?
    var id: String { name }
    var reclaimable: Bool { status == "Released" || status == "Available" }
}

struct PodInfo {
    let namespace: String
    let name: String
    let pvcNames: [String]   // PVCs this pod mounts
}

enum K8sProbe {
    static func contexts() -> [K8sContext] {
        guard let kubectl = VMProbe.locate("kubectl") else { return [] }
        let current = VMProbe.capture(kubectl, ["config", "current-context"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let list = VMProbe.capture(kubectl, ["config", "get-contexts", "-o", "name"]) else { return [] }
        return list.split(whereSeparator: \.isNewline).map {
            let name = String($0)
            return K8sContext(name: name, isCurrent: name == current)
        }
    }
}

/// Granular queries so the controller can fill the UI progressively (PVCs first,
/// then pods, then live usage node-by-node) rather than blocking on one call.
enum K8sQueries {
    static func pvcs(context: String) -> [PVCInfo] {
        guard let kubectl = VMProbe.locate("kubectl"),
              let items = jsonItems(kubectl, context, ["get", "pvc", "-A", "-o", "json"]) else { return [] }
        return items.map { item in
            let meta = item["metadata"] as? [String: Any] ?? [:]
            let spec = item["spec"] as? [String: Any] ?? [:]
            let status = item["status"] as? [String: Any] ?? [:]
            let capStr = (status["capacity"] as? [String: Any])?["storage"] as? String
            let reqStr = ((spec["resources"] as? [String: Any])?["requests"] as? [String: Any])?["storage"] as? String
            return PVCInfo(
                namespace: meta["namespace"] as? String ?? "",
                name: meta["name"] as? String ?? "",
                capacity: parseQuantity(capStr ?? reqStr),
                used: nil,
                accessModes: spec["accessModes"] as? [String] ?? [],
                storageClass: spec["storageClassName"] as? String ?? "—",
                phase: status["phase"] as? String ?? "?",
                volumeName: spec["volumeName"] as? String
            )
        }
    }

    static func pods(context: String) -> [PodInfo] {
        guard let kubectl = VMProbe.locate("kubectl"),
              let items = jsonItems(kubectl, context, ["get", "pods", "-A", "-o", "json"]) else { return [] }
        var pods: [PodInfo] = []
        for item in items {
            let meta = item["metadata"] as? [String: Any] ?? [:]
            let spec = item["spec"] as? [String: Any] ?? [:]
            let volumes = spec["volumes"] as? [[String: Any]] ?? []
            let claims = volumes.compactMap { ($0["persistentVolumeClaim"] as? [String: Any])?["claimName"] as? String }
            guard !claims.isEmpty else { continue }
            pods.append(PodInfo(
                namespace: meta["namespace"] as? String ?? "",
                name: meta["name"] as? String ?? "",
                pvcNames: claims
            ))
        }
        return pods
    }

    static func pvs(context: String) -> [PVInfo] {
        guard let kubectl = VMProbe.locate("kubectl"),
              let items = jsonItems(kubectl, context, ["get", "pv", "-o", "json"]) else { return [] }
        return items.map { item in
            let meta = item["metadata"] as? [String: Any] ?? [:]
            let spec = item["spec"] as? [String: Any] ?? [:]
            let status = item["status"] as? [String: Any] ?? [:]
            let capStr = (spec["capacity"] as? [String: Any])?["storage"] as? String
            let claimRef = spec["claimRef"] as? [String: Any]
            let claim = claimRef.map { "\($0["namespace"] as? String ?? "")/\($0["name"] as? String ?? "")" }
            return PVInfo(
                name: meta["name"] as? String ?? "",
                capacity: parseQuantity(capStr),
                status: status["phase"] as? String ?? "?",
                storageClass: spec["storageClassName"] as? String ?? "—",
                reclaimPolicy: spec["persistentVolumeReclaimPolicy"] as? String ?? "—",
                claim: claim
            )
        }
    }

    static func nodeNames(context: String) -> [String] {
        guard let kubectl = VMProbe.locate("kubectl"),
              let items = jsonItems(kubectl, context, ["get", "nodes", "-o", "json"]) else { return [] }
        return items.compactMap { ($0["metadata"] as? [String: Any])?["name"] as? String }
    }

    /// Live used bytes per PVC reported by one node's kubelet stats.
    static func nodeUsage(context: String, node: String) -> [String: Int64] {
        guard let kubectl = VMProbe.locate("kubectl"),
              let raw = VMProbe.capture(kubectl, ["--context", context, "get", "--raw",
                                                  "/api/v1/nodes/\(node)/proxy/stats/summary"]),
              let data = raw.data(using: .utf8),
              let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pods = summary["pods"] as? [[String: Any]] else { return [:] }
        var usage: [String: Int64] = [:]
        for pod in pods {
            for vol in (pod["volume"] as? [[String: Any]]) ?? [] {
                guard let ref = vol["pvcRef"] as? [String: Any],
                      let ns = ref["namespace"] as? String,
                      let name = ref["name"] as? String else { continue }
                usage["\(ns)/\(name)"] = int64(vol["usedBytes"])
            }
        }
        return usage
    }

    // MARK: helpers

    private static func jsonItems(_ kubectl: String, _ context: String, _ args: [String]) -> [[String: Any]]? {
        guard let json = VMProbe.capture(kubectl, ["--context", context] + args),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["items"] as? [[String: Any]]
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let i = value as? Int64 { return i }
        if let i = value as? Int { return Int64(i) }
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String { return Int64(s) ?? 0 }
        return 0
    }

    /// Parse a Kubernetes resource quantity ("8Gi", "100Mi", "1Ti", "500M") → bytes.
    static func parseQuantity(_ value: String?) -> Int64 {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return 0 }
        let units: [(String, Double)] = [
            ("Ki", 1024), ("Mi", 1_048_576), ("Gi", 1_073_741_824),
            ("Ti", 1_099_511_627_776), ("Pi", 1_125_899_906_842_624),
            ("k", 1e3), ("K", 1e3), ("M", 1e6), ("G", 1e9), ("T", 1e12), ("P", 1e15),
        ]
        for (suffix, mult) in units where raw.hasSuffix(suffix) {
            let number = Double(raw.dropLast(suffix.count)) ?? 0
            return Int64(number * mult)
        }
        return Int64(Double(raw) ?? 0)
    }
}
