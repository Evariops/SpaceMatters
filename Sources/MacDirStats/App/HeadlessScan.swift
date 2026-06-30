import Foundation

/// Headless scan used for benchmarking / correctness checks:
///   MacDirStats --scan /path [/more/paths ...]
///   MacDirStats --volumes
/// Prints totals and timing, then exits. Lets the engine be validated without
/// bringing up the GUI.
enum HeadlessScan {
    static func run(paths: [String]) {
        guard !paths.isEmpty else {
            print("usage: MacDirStats --scan <path> [more paths ...]")
            return
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
        let files = root.fileCount.load(ordering: .relaxed)
        let dirs = scanner.dirCount.load(ordering: .relaxed)
        let errors = scanner.errorCount.load(ordering: .relaxed)

        print("roots:     \(paths.count)")
        print("files:     \(files)")
        print("dirs:      \(dirs)")
        print("logical:   \(logical) bytes  (\(Format.bytes(logical)))")
        print("physical:  \(physical) bytes  (\(Format.bytes(physical)))")
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

        let top = scanner.snapshotExtensions(metric: .physical, limit: 8)
        if !top.isEmpty {
            print("top types:")
            for row in top {
                print(String(format: "  %-18@ %12@  (%@ files)", row.name as NSString,
                             Format.bytes(row.physical) as NSString, Format.count(row.count) as NSString))
            }
        }
    }

    /// Headless VM scan that prints rising counts as the stream arrives — proves
    /// the find-over-SSH backend updates progressively, not in one blocking call.
    static func runVM(runtime: String, scope: String) {
        let machines = VMProbe.detect()
        print("detected VMs:")
        for m in machines {
            print("  \(m.runtime.rawValue) \(m.name) — \(m.running ? "running" : "stopped"), disk \(Format.bytes(m.diskBytes))")
        }
        guard let machine = machines.first(where: { $0.runtime.rawValue.lowercased() == runtime.lowercased() }) else {
            print("no \(runtime) machine found"); return
        }
        guard machine.running else { print("\(machine.runtime.rawValue) is not running — cannot scan"); return }

        let vmScope: VMScope = (scope.lowercased() == "containers") ? .containers : .full
        let cmd = VMProbe.scanCommand(machine: machine, scope: vmScope)
        print("scanning \(machine.runtime.rawValue) (\(vmScope.rawValue)) root=\(cmd.rootPath)")

        let root = FSNode(name: machine.name, parent: nil)
        let scanner = CommandScanner(root: root, rootPath: cmd.rootPath, executable: cmd.executable, arguments: cmd.arguments)
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

        print(String(format: "DONE in %.2fs — dirs=%d files=%d  on-disk=%@  logical=%@",
                     Date().timeIntervalSince(start), scanner.directoryCount,
                     root.fileCount.load(ordering: .relaxed),
                     Format.bytes(root.aggPhysical.load(ordering: .relaxed)),
                     Format.bytes(root.aggLogical.load(ordering: .relaxed))))
        for row in scanner.snapshotExtensions(metric: .physical, limit: 6) {
            print("  \(row.name): \(Format.bytes(row.physical)) (\(Format.count(row.count)) files)")
        }
    }

    static func runContainers() {
        guard let engine = ContainerProbe.detect().first else { print("no reachable container engine"); return }
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
