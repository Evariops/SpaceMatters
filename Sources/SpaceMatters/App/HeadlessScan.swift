import Foundation

/// Headless scan used for benchmarking / correctness checks:
///   SpaceMatters --scan /path [/more/paths ...]
///   SpaceMatters --volumes
/// Prints totals and timing, then exits. Lets the engine be validated without
/// bringing up the GUI.
enum HeadlessScan {
    /// Returns a process exit code so scripts/CI can tell a bad invocation from a
    /// clean scan (a nonexistent path used to "succeed" with exit 0).
    @discardableResult
    static func run(paths: [String]) -> Int32 {
        guard !paths.isEmpty else {
            print("usage: SpaceMatters --scan <path> [more paths ...]")
            return 2
        }
        let fm = FileManager.default
        for p in paths where !fm.fileExists(atPath: p) {
            FileHandle.standardError.write(Data("error: path does not exist: \(p)\n".utf8))
            return 1
        }

        let root: FSNode
        var seeds: [DirectoryScanner.Seed] = []
        if paths.count == 1 {
            let url = URL(fileURLWithPath: paths[0])
            root = FSNode(name: url.lastPathComponent, parent: nil)
            seeds = [.init(path: url.path, node: root)]
        } else {
            root = FSNode(name: "\(paths.count) roots", parent: nil)
            var children: [FSNode] = []
            for p in paths {
                let node = FSNode(name: URL(fileURLWithPath: p).lastPathComponent, parent: root)
                children.append(node)
                seeds.append(.init(path: p, node: node))
            }
            root.finishScan(children: children, filesLogical: 0, filesPhysical: 0, fileCount: 0)
        }

        let skip = DirectoryScanner.recommendedSkipPaths(seedPaths: seeds.map(\.path))
        let scanner = DirectoryScanner(root: root, seeds: seeds, skipPaths: skip)
        let start = Date()
        scanner.start()
        while !scanner.isFinished { usleep(20_000) }
        let elapsed = Date().timeIntervalSince(start)

        let logical = root.aggLogical.load(ordering: .relaxed)
        let physical = root.aggPhysical.load(ordering: .relaxed)
        let sparse = root.aggSparseExcess.load(ordering: .relaxed)
        let compressed = root.aggCompressedExcess.load(ordering: .relaxed)
        let files = root.fileCount.load(ordering: .relaxed)
        let dirs = scanner.dirCount.load(ordering: .relaxed)
        let errors = scanner.errorCount.load(ordering: .relaxed)

        print("roots:     \(paths.count)")
        print("files:     \(files)")
        print("dirs:      \(dirs)")
        print("on-disk:   \(physical) bytes  (\(Format.bytes(physical)))")
        print("apparent:  \(logical) bytes  (\(Format.bytes(logical)))")
        if sparse > 0 { print("sparse:    \(sparse) bytes not allocated  (\(Format.bytes(sparse)))") }
        if compressed > 0 { print("compressed:\(compressed) bytes saved  (\(Format.bytes(compressed)))") }
        print("errors:    \(errors)")
        print(String(format: "elapsed:   %.3f s  (%.0f files/s)", elapsed, Double(files) / max(elapsed, 0.001)))

        if paths.count > 1 {
            print("per root:")
            for child in root.children {
                print(String(format: "  %-24@ %12@",
                             child.name as NSString,
                             Format.bytes(child.aggPhysical.load(ordering: .relaxed)) as NSString))
            }
        }

        let top = scanner.snapshotExtensions(limit: 8)
        if !top.isEmpty {
            print("top types:")
            for row in top {
                print(String(format: "  %-18@ %12@  (%@ files)", row.name as NSString,
                             Format.bytes(row.physical) as NSString, Format.count(row.count) as NSString))
            }
        }
        return 0
    }

    /// Headless VM scan that prints rising counts as the stream arrives — proves
    /// the find-over-SSH backend updates progressively, not in one blocking call.
    /// Returns an exit code (0 ok, 1 failure) so scripts can rely on it.
    @discardableResult
    static func runVM(runtime: String, scope: String) -> Int32 {
        let machines = VMProbe.detect()
        print("detected VMs:")
        for m in machines {
            print("  \(m.runtime.rawValue) \(m.name) — \(m.running ? "running" : "stopped"), disk \(Format.bytes(m.diskBytes))")
        }
        guard let machine = machines.first(where: { $0.runtime.rawValue.lowercased() == runtime.lowercased() }) else {
            FileHandle.standardError.write(Data("error: no \(runtime) machine found\n".utf8)); return 1
        }
        guard machine.running else {
            FileHandle.standardError.write(Data("error: \(machine.runtime.rawValue) is not running — cannot scan\n".utf8))
            return 1
        }

        let vmScope: VMScope = (scope.lowercased() == "containers") ? .containers : .full
        let cmd = VMProbe.scanCommand(machine: machine, scope: vmScope)
        print("scanning \(machine.runtime.rawValue) (\(vmScope.rawValue)) root=\(cmd.rootPath)")

        let root = FSNode(name: machine.name, parent: nil)
        let scanner = CommandScanner(
            root: root, rootPath: cmd.rootPath, executable: cmd.executable, arguments: cmd.arguments,
            source: .vm("\(machine.runtime.rawValue) — \(vmScope.rawValue)"))
        let start = Date()
        scanner.start()

        var last: Int64 = -1
        while !scanner.isFinished {
            usleep(250_000)
            let files = root.fileCount.load(ordering: .relaxed)
            if files != last {
                print(String(format: "  [%5.1fs] dirs=%-7d files=%-8d on-disk=%@",
                             Date().timeIntervalSince(start), scanner.directoryCount, files,
                             Format.bytes(root.aggPhysical.load(ordering: .relaxed))))
                last = files
            }
        }

        print(String(format: "DONE in %.2fs — dirs=%d files=%d  on-disk=%@  apparent=%@",
                     Date().timeIntervalSince(start), scanner.directoryCount,
                     root.fileCount.load(ordering: .relaxed),
                     Format.bytes(root.aggPhysical.load(ordering: .relaxed)),
                     Format.bytes(root.aggLogical.load(ordering: .relaxed))))
        for row in scanner.snapshotExtensions(limit: 6) {
            print("  \(row.name): \(Format.bytes(row.physical)) (\(Format.count(row.count)) files)")
        }
        if let failure = scanner.failure {
            FileHandle.standardError.write(Data("error: \(failure)\n".utf8))
            return 1
        }
        return 0
    }

    @discardableResult
    static func runContainers() -> Int32 {
        guard let engine = ContainerProbe.detect().first else {
            FileHandle.standardError.write(Data("error: no reachable container engine\n".utf8)); return 1
        }
        print("engine: \(engine.displayName) (\(engine.executable))")
        let snap = ContainerQueries.fetchAll(engine)
        print("df:")
        for r in snap.df {
            print("  \(r.type): size=\(Format.bytes(r.size)) reclaimable=\(Format.bytes(r.reclaimable)) total=\(r.total) active=\(r.active)")
        }
        print("images: \(snap.images.count)")
        for img in snap.images.sorted(by: { $0.size > $1.size }).prefix(5) {
            print("  \(img.name) [\(img.shortID)] \(Format.bytes(img.size)) inUse=\(img.inUse)")
        }
        if let biggest = snap.images.max(by: { $0.size < $1.size }) {
            print("layers of \(biggest.name):")
            for layer in ContainerQueries.history(engine, imageID: biggest.id).prefix(8) {
                print(String(format: "  %9@  %@", Format.bytes(layer.size) as NSString, String(layer.command.prefix(64)) as NSString))
            }
        }
        print("containers: \(snap.containers.count), volumes: \(snap.volumes.count)")
        return 0
    }

    @discardableResult
    static func runK8s(context: String?) -> Int32 {
        let contexts = K8sProbe.contexts()
        print("contexts: \(contexts.map { $0.isCurrent ? "\($0.name)*" : $0.name }.joined(separator: ", "))")
        guard let ctx = context ?? contexts.first(where: \.isCurrent)?.name ?? contexts.first?.name else {
            FileHandle.standardError.write(Data("error: no kube context\n".utf8)); return 1
        }
        print("analyzing context: \(ctx)")
        var pvcs = K8sQueries.pvcs(context: ctx)
        let pods = K8sQueries.pods(context: ctx)
        let pvs = K8sQueries.pvs(context: ctx)
        var usage: [String: Int64] = [:]
        for node in K8sQueries.nodeNames(context: ctx) {
            for (k, v) in K8sQueries.nodeUsage(context: ctx, node: node) { usage[k] = v }
        }
        pvcs = pvcs.map { var p = $0; if let u = usage[p.id] { p.used = u }; return p }

        let totalCap = pvcs.reduce(0) { $0 + $1.capacity }
        let totalUsed = pvcs.compactMap(\.used).reduce(0, +)
        print("PVCs: \(pvcs.count)  pods-with-PVC=\(pods.count)  capacity=\(Format.bytes(totalCap))  used=\(Format.bytes(totalUsed))")
        for pvc in pvcs.sorted(by: { $0.capacity > $1.capacity }).prefix(8) {
            let u = pvc.used.map { "\(Format.bytes($0))/\(Format.bytes(pvc.capacity)) (\(Int((pvc.usageFraction ?? 0) * 100))%)" } ?? "—"
            print("  \(pvc.namespace)/\(pvc.name)  \(u)  \(pvc.accessShort)  \(pvc.storageClass)  \(pvc.phase)")
        }
        let reclaimable = pvs.filter(\.reclaimable)
        print("PVs: \(pvs.count)  reclaimable=\(reclaimable.count) (\(Format.bytes(reclaimable.reduce(0) { $0 + $1.capacity })))")
        return 0
    }

    static func listVolumes() {
        for v in Volume.mounted() {
            print(String(format: "%-28@ %@  total=%@  free=%@  %@%@",
                         v.name as NSString,
                         v.url.path as NSString,
                         Format.bytes(v.total) as NSString,
                         Format.bytes(v.available) as NSString,
                         (v.isRoot ? "[root] " : "") as NSString,
                         v.kindLabel as NSString))
        }
    }
}
