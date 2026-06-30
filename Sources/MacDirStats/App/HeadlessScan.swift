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
