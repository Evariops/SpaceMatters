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

    /// Where the row's name came from, and therefore what the image *is*.
    ///
    /// An untagged image listed as `<none>` tells the user nothing, and on a
    /// machine that rebuilds the same tags all day there are hundreds of them —
    /// 200 of 227 here. But the engine does know what each one was: when a
    /// build or a pull moves a tag to a new image, the old one keeps the tag it
    /// used to carry in its `History`. Reading that turns an unreadable wall of
    /// `<none>` into "37 superseded builds of harness/runner-local:latest",
    /// which is both legible and the actual finding.
    enum Origin: Equatable {
        /// Carries a repository and tag right now.
        case tagged
        /// Untagged because a newer image took its tag. The name is that tag.
        case superseded
        /// A buildah/BuildKit scratch image from an interrupted or multi-stage
        /// build — never had a real tag and never will.
        case buildIntermediate
        /// No tag, but pulled by digest, so the repository is still known.
        case digest
        /// Identified only by its OCI labels (`image.title` / `image.source`).
        case labelled
        /// Nothing identifies it — the honest `<none>`.
        case anonymous

        /// Short badge shown beside the name, or nil when the name speaks for
        /// itself. This is the *reason* the row is not a normal tagged image;
        /// without it a resolved name would imply the tag still points here.
        var badge: String? {
            switch self {
            case .tagged: return nil
            case .superseded: return "superseded"
            case .buildIntermediate: return "build leftover"
            case .digest: return "untagged"
            case .labelled: return "untagged"
            case .anonymous: return "unidentified"
            }
        }
    }

    let id: String
    /// Best available identity: the tag it carries, else the tag it used to
    /// carry, else its repository or label. `<none>` only when nothing is known.
    let name: String
    let size: Int64
    let inUse: Bool
    let created: Date?
    var origin: Origin = .tagged
    /// Bytes only this image holds — what removing *this* row would free.
    ///
    /// `size` is the image's full extent including every layer it shares with
    /// others, so a list of them sums to far more than the disk holds: 100.8 GiB
    /// of rows against 17.3 GiB of actual images on this machine. Shown when the
    /// two diverge, because "265 MB" on a row that frees 6 KB is the single most
    /// misleading number in this view. Nil when the engine does not report it.
    var uniqueSize: Int64?

    var shortID: String { String(id.prefix(12)) }
    var dangling: Bool { origin != .tagged }
    /// True when `size` badly overstates what deleting this row frees.
    var sharesMostOfItsBytes: Bool {
        guard let uniqueSize, size > 0 else { return false }
        return Double(uniqueSize) / Double(size) < 0.5
    }
}

/// Images that resolve to the same identity — the tag they carry or used to.
///
/// One row per image is unreadable when a tag has been rebuilt forty times; one
/// row per identity says what is actually on the disk, and the images stay one
/// disclosure away.
struct CImageGroup: Identifiable {
    let name: String
    let images: [CImage]
    var id: String { name }

    /// Sum of the members' extents. Deliberately **not** presented as what
    /// removing the group frees, and there is no property here that claims to
    /// be: layers shared between the members belong to none of them
    /// individually, so the per-image unique sizes sum to far too little (0 B
    /// for a group of 38 rebuilds measured here) while this figure counts every
    /// shared layer once per member and so is far too much. The engine's own
    /// `system df` reclaimable, on the Images card, is the only honest total —
    /// inventing a per-group one would just be a third wrong number.
    var size: Int64 { images.reduce(0) { $0 + $1.size } }

    var unusedCount: Int { images.filter { !$0.inUse }.count }
    var supersededCount: Int { images.filter { $0.origin == .superseded }.count }
    /// A lone image needs no group wrapper — it renders as a plain row.
    var isSingle: Bool { images.count == 1 }

    /// True when the members are near-identical rebuilds: each holds almost
    /// nothing of its own, because they share their layers with each other.
    ///
    /// Worth saying out loud, because it changes the advice. Deleting old builds
    /// one at a time here frees nothing at all — only removing the whole set
    /// releases the layers underneath them.
    var layersMostlyShared: Bool {
        let measured = images.compactMap(\.uniqueSize)
        guard measured.count == images.count, images.count > 1, size > 0 else { return false }
        return Double(measured.reduce(0, +)) / Double(size) < 0.1
    }
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
        let unique = uniqueSizes(engine)
        return arr.map { m in
            let id = m["Id"] as? String ?? ""
            let (name, origin) = identify(m)
            return CImage(
                id: id,
                name: name,
                size: int64(m["Size"]),
                inUse: (int(m["Containers"]) ?? 0) > 0,
                created: date(m["Created"]),
                origin: origin,
                uniqueSize: unique[String(id.prefix(12))]
            )
        }
    }

    /// The best name for an image, and where that name came from.
    ///
    /// Tried in descending order of how firmly the name still applies: a live
    /// tag, then a repository known by digest, then the tag the image used to
    /// carry before something newer took it, then whatever its OCI labels
    /// declare. Internal so the ladder can be pinned in tests against real
    /// engine payloads — every rung below the first is inference, and inference
    /// presented as an image's name has to be right.
    static func identify(_ m: [String: Any]) -> (name: String, origin: CImage.Origin) {
        let names = ((m["Names"] as? [String]) ?? (m["RepoTags"] as? [String]) ?? [])
            .filter { !$0.hasSuffix(":<none>") && $0 != "<none>" }
        if let tag = names.first {
            // An image pulled by digest is named `repo@sha256:<64 hex>`. That is
            // its real name, but 71 characters of hash crowds every other row
            // off the line and distinguishes nothing — the repository plus a
            // badge says the same thing legibly.
            if let repo = tag.components(separatedBy: "@sha256:").first, repo != tag, !repo.isEmpty {
                return (repo, .digest)
            }
            return (tag, .tagged)
        }

        // Docker's flat form: separate Repository/Tag columns.
        if let repo = m["Repository"] as? String, repo != "<none>", !repo.isEmpty {
            let tag = m["Tag"] as? String ?? ""
            return (tag.isEmpty || tag == "<none>" ? repo : "\(repo):\(tag)", .digest)
        }
        if let digests = m["RepoDigests"] as? [String],
           let repo = digests.first?.components(separatedBy: "@").first, !repo.isEmpty {
            return (repo, .digest)
        }
        // `History` holds the names this image has answered to. For an untagged
        // image the last one is the tag it lost.
        if let history = m["History"] as? [String], let previous = history.last, !previous.isEmpty {
            return isBuildIntermediate(previous)
                ? ("build leftover", .buildIntermediate)
                : (previous, .superseded)
        }
        if let labels = m["Labels"] as? [String: String] {
            for key in ["org.opencontainers.image.title", "org.opencontainers.image.source"] {
                if let value = labels[key], !value.isEmpty { return (value, .labelled) }
            }
        }
        return ("<none>", .anonymous)
    }

    /// A buildah scratch name: `docker.io/library/<64 hex>-tmp:latest`. It is a
    /// former name like any other, but naming the row after it would invent a
    /// repository that never existed. Internal for tests.
    static func isBuildIntermediate(_ name: String) -> Bool {
        let repo = name.components(separatedBy: ":").first ?? name
        guard let last = repo.components(separatedBy: "/").last, last.hasSuffix("-tmp") else {
            return false
        }
        let stem = last.dropLast(4)
        return stem.count >= 12 && stem.allSatisfy(\.isHexDigit)
    }

    /// Short image id → bytes only that image holds.
    ///
    /// `podman system df -v` is the only place the engine reports this, and it
    /// refuses `--format json` alongside `--verbose`, so the table is parsed.
    /// Read from both ends rather than by column: the first three fields
    /// (repository, tag, id) and the last four (size, shared, unique,
    /// containers) are single tokens, while CREATED in between is a human
    /// duration of unpredictable width ("3 weeks", "About a minute"). Any line
    /// that does not fit is skipped — a missing unique size costs a hint, a
    /// misparsed one would misreport what a deletion frees.
    static func uniqueSizes(_ engine: ContainerEngine) -> [String: Int64] {
        guard engine.kind == .podman,
              let out = VMProbe.capture(engine.executable, ["system", "df", "-v"], timeout: 30)
        else { return [:] }
        return parseUniqueSizes(out)
    }

    /// Internal for tests — the format is podman's and can change under us.
    static func parseUniqueSizes(_ output: String) -> [String: Int64] {
        var result: [String: Int64] = [:]
        var inImages = false
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if text.contains("space usage:") {
                inImages = text.lowercased().hasPrefix("images")
                continue
            }
            guard inImages else { continue }
            let fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 8, fields[0] != "REPOSITORY" else { continue }
            let id = fields[2]
            guard id.count >= 12, id.allSatisfy(\.isHexDigit) else { continue }
            result[id] = parseHumanSize(fields[fields.count - 2])
        }
        return result
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
