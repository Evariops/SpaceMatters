import Foundation

/// A reachable container engine. Unlike VM filesystem scans, the host `podman`/
/// `docker` CLI talks to the engine directly (no SSH), so queries are fast.
struct ContainerEngine: Identifiable {
    enum Kind: String { case podman = "Podman", docker = "Docker" }
    let kind: Kind
    let executable: String
    var id: String { kind.rawValue }
    var displayName: String { kind.rawValue }
}

// MARK: Domain model

struct CImage: Identifiable {
    let id: String
    let name: String          // best repo:tag, or "<none>"
    let size: Int64
    let inUse: Bool
    let created: Date?
    var shortID: String { String(id.prefix(12)) }
    var dangling: Bool { name == "<none>" || name.hasSuffix(":<none>") }
}

struct CLayer: Identifiable {
    let index: Int
    let size: Int64
    let command: String
    var id: Int { index }
}

struct CContainer: Identifiable {
    let id: String
    let name: String
    let image: String
    let status: String
    let size: Int64
    var shortID: String { String(id.prefix(12)) }
    var running: Bool { status.lowercased().contains("up") || status.lowercased() == "running" }
}

struct CVolume: Identifiable {
    let name: String
    let size: Int64
    let inUse: Bool
    var id: String { name }
}

/// The host-side disk image backing a Podman machine, and what it actually
/// occupies.
///
/// A Podman machine's disk is a sparse file: it declares its full configured
/// size and allocates blocks as the guest writes them. Deleting things inside
/// the guest frees guest space but leaves those host blocks allocated — which
/// is why a `system prune` that reclaims 15 GB inside can leave the `.raw`
/// exactly as large as before, and why the usual advice ("podman disks never
/// shrink, recreate the machine") gets written.
///
/// It is wrong: applehv's virtio-blk advertises discard, and Fedora CoreOS runs
/// `fstrim.timer` weekly. The blocks do come back — just up to a week late.
/// `ContainerActions.trim` is that timer, on demand.
struct CMachineDisk {
    let machine: String
    let imagePath: String
    /// Blocks actually allocated on the host (`st_blocks`) — what deleting the
    /// file would free, and the only number that moves when the guest is
    /// trimmed.
    let onDisk: Int64
    /// The size the guest sees, and the file's apparent length. Always ≥
    /// `onDisk`; quoting it as reclaimable is the classic sparse-file error.
    let apparent: Int64
}

/// A row of `system df` (authoritative sizes, deduped across shared layers).
struct CDFRow: Identifiable {
    let type: String
    let total: Int
    let active: Int
    let size: Int64
    let reclaimable: Int64
    var id: String { type }
}

// MARK: Detection

enum ContainerProbe {
    static func detect() -> [ContainerEngine] {
        var engines: [ContainerEngine] = []
        // Podman: a machine must be running for the CLI to connect.
        if let podman = VMProbe.locate("podman"), podmanReachable(podman) {
            engines.append(ContainerEngine(kind: .podman, executable: podman))
        }
        // Docker (Desktop / colima-docker): reachable only when the daemon is up.
        if let docker = VMProbe.locate("docker"), dockerReachable(docker) {
            engines.append(ContainerEngine(kind: .docker, executable: docker))
        }
        return engines
    }

    private static func podmanReachable(_ executable: String) -> Bool {
        guard let json = VMProbe.capture(executable, ["machine", "list", "--format", "json"]),
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        return arr.contains { ($0["Running"] as? Bool) ?? false }
    }

    private static func dockerReachable(_ executable: String) -> Bool {
        // `docker info` only prints a server version when the daemon answers.
        guard let out = VMProbe.capture(executable, ["info", "--format", "{{.ServerVersion}}"], timeout: 8) else { return false }
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: Queries (Podman JSON)

enum ContainerQueries {
    struct Snapshot {
        var df: [CDFRow] = []
        var images: [CImage] = []
        var containers: [CContainer] = []
        var volumes: [CVolume] = []
        /// Podman only, and only when the image file can be located.
        var machineDisk: CMachineDisk?
    }

    static func fetchAll(_ engine: ContainerEngine) -> Snapshot {
        Snapshot(df: df(engine), images: images(engine), containers: containers(engine),
                 volumes: volumes(engine), machineDisk: machineDisk(engine))
    }

    /// The running machine's disk image, measured on the host.
    ///
    /// Podman does not report the image path, so it is derived from the one
    /// machine path it does report — `SSHConfig.IdentityPath`, which sits in the
    /// machine root next to the per-provider directories. The file is then found
    /// by name rather than by guessing the provider and the architecture suffix.
    /// Nothing here is fatal: no path found simply means no reclaim row.
    static func machineDisk(_ engine: ContainerEngine) -> CMachineDisk? {
        guard engine.kind == .podman,
              let arr = jsonArray(engine, ["machine", "inspect"]),
              let machine = arr.first(where: { ($0["State"] as? String) == "running" }),
              let name = machine["Name"] as? String,
              let ssh = machine["SSHConfig"] as? [String: Any],
              let identity = ssh["IdentityPath"] as? String
        else { return nil }

        let machineRoot = (identity as NSString).deletingLastPathComponent
        guard let path = findDiskImage(machineRoot: machineRoot, name: name) else { return nil }
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return CMachineDisk(machine: name, imagePath: path,
                            onDisk: Int64(st.st_blocks) * 512, apparent: Int64(st.st_size))
    }

    /// `<machineRoot>/<provider>/<name>*.raw`. Internal for tests — the layout
    /// is podman's, not ours, and a provider rename must fail loudly in CI
    /// rather than quietly drop the reclaim row.
    static func findDiskImage(machineRoot: String, name: String,
                              fm: FileManager = .default) -> String? {
        guard let providers = try? fm.contentsOfDirectory(atPath: machineRoot) else { return nil }
        for provider in providers {
            let dir = machineRoot + "/" + provider
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            if let image = entries.first(where: { $0.hasPrefix(name) && $0.hasSuffix(".raw") }) {
                return dir + "/" + image
            }
        }
        return nil
    }

    static func df(_ engine: ContainerEngine) -> [CDFRow] {
        guard let arr = jsonArray(engine, ["system", "df", "--format", "json"]) else { return [] }
        return arr.map { m in
            CDFRow(
                type: m["Type"] as? String ?? "",
                total: int(m["TotalCount"]) ?? int(m["Total"]) ?? 0,
                active: int(m["Active"]) ?? 0,
                size: int64(m["RawSize"]),
                reclaimable: int64(m["RawReclaimable"])
            )
        }
    }

    static func images(_ engine: ContainerEngine) -> [CImage] {
        guard let arr = jsonArray(engine, ["images", "--format", "json"]) else { return [] }
        return arr.map { m in
            let names = (m["Names"] as? [String]) ?? (m["RepoTags"] as? [String]) ?? []
            return CImage(
                id: m["Id"] as? String ?? "",
                name: names.first ?? "<none>",
                size: int64(m["Size"]),
                inUse: (int(m["Containers"]) ?? 0) > 0,
                created: date(m["Created"])
            )
        }
    }

    static func containers(_ engine: ContainerEngine) -> [CContainer] {
        guard let arr = jsonArray(engine, ["ps", "-a", "--size", "--format", "json"]) else { return [] }
        return arr.map { m in
            let names = (m["Names"] as? [String]) ?? []
            return CContainer(
                id: m["Id"] as? String ?? (m["ID"] as? String ?? ""),
                name: names.first ?? (m["Names"] as? String ?? ""),
                image: m["Image"] as? String ?? "",
                status: (m["Status"] as? String) ?? (m["State"] as? String ?? ""),
                size: int64(m["Size"]) + int64(m["RwSize"])
            )
        }
    }

    static func volumes(_ engine: ContainerEngine) -> [CVolume] {
        guard let arr = jsonArray(engine, ["volume", "ls", "--format", "json"]) else { return [] }
        return arr.map { m in
            CVolume(name: m["Name"] as? String ?? "", size: int64(m["Size"]), inUse: (int(m["Containers"]) ?? 0) > 0)
        }
    }

    /// An image's layers (size + the build command that created it), bottom→top.
    static func history(_ engine: ContainerEngine, imageID: String) -> [CLayer] {
        guard let arr = jsonArray(engine, ["history", imageID, "--format", "json"]) else { return [] }
        return arr.reversed().enumerated().map { idx, m in
            CLayer(index: idx, size: int64(m["size"] ?? m["Size"]), command: cleanCommand(m["CreatedBy"] as? String ?? ""))
        }
    }

    /// Internal (not private) so tests can pin the layer-command cleanup.
    static func cleanCommand(_ raw: String) -> String {
        var s = raw
        // Strip the buildkit/buildah arg prefix like "|3 KEY=v ... /bin/sh -c ".
        if let range = s.range(of: "/bin/sh -c ") { s = String(s[range.upperBound...]) }
        if s.hasPrefix("#(nop) ") { s = String(s.dropFirst(7)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: helpers

    private static func jsonArray(_ engine: ContainerEngine, _ args: [String]) -> [[String: Any]]? {
        guard let json = VMProbe.capture(engine.executable, args) else { return nil }
        return parseJSONArray(json)
    }

    /// Parse `--format json` output: a JSON array, or JSONL (one object per
    /// line — some podman/docker commands emit that). Internal for tests.
    static func parseJSONArray(_ json: String) -> [[String: Any]]? {
        guard let data = json.data(using: .utf8) else { return nil }
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return arr }
        var out: [[String: Any]] = []
        for line in json.split(whereSeparator: \.isNewline) {
            if let d = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                out.append(obj)
            }
        }
        return out.isEmpty ? nil : out
    }

    private static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let i = value as? Int64 { return i }
        if let i = value as? Int { return Int64(i) }
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String {
            if let plain = Int64(s) { return plain }
            return parseHumanSize(s) // docker reports sizes as "1.2GB", "512MB", "0B"
        }
        return 0
    }

    /// Parse a docker-style human size ("1.2GB", "512MB", "0B") to bytes. Decimal
    /// units, matching docker's own output. Returns 0 for anything unrecognised.
    /// Internal (not private) so tests can pin it — it drives the Reclaim button.
    static func parseHumanSize(_ raw: String) -> Int64 {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [
            ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1),
        ]
        for (suffix, mult) in units where s.hasSuffix(suffix) {
            let num = s.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            if let v = Double(num) { return Int64(v * mult) }
        }
        return 0
    }

    private static func date(_ value: Any?) -> Date? {
        if let secs = int(value), secs > 0 { return Date(timeIntervalSince1970: TimeInterval(secs)) }
        return nil
    }
}
