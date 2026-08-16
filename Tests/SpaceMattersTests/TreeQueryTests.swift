import Testing
import Foundation
@testable import SpaceMatters

/// SPEC-14 phase 2 — the query layer the MCP tools sit on. The subtle parts are
/// the fence (a path outside the scan must fail, never wander onto the real
/// filesystem) and not double-counting nested matches.
@Suite struct TreeQueryTests {

    private func leaf(_ name: String, in parent: FSNode?, bytes: Int64, files: Int64 = 1) -> FSNode {
        let node = FSNode(name: name, parent: parent)
        node.finishScan(children: [], filesLogical: bytes, filesPhysical: bytes, fileCount: files)
        node.aggPhysical.store(bytes, ordering: .relaxed)
        node.fileCount.store(files, ordering: .relaxed)
        return node
    }

    private func branch(_ name: String, in parent: FSNode?, children build: (FSNode) -> [FSNode]) -> FSNode {
        let node = FSNode(name: name, parent: parent)
        let kids = build(node)
        node.finishScan(children: kids, filesLogical: 0, filesPhysical: 0, fileCount: 0)
        node.aggPhysical.store(kids.reduce(0) { $0 + $1.sizeOnDisk }, ordering: .relaxed)
        return node
    }

    /// `/root` → `app` → `node_modules` → `nested` → `node_modules`
    private func nestedFixture() -> FSNode {
        branch("root", in: nil) { r in
            [branch("app", in: r) { a in
                [branch("node_modules", in: a) { nm in
                    [leaf("pkg", in: nm, bytes: 700),
                     branch("nested", in: nm) { n in [leaf("node_modules", in: n, bytes: 300)] }]
                }]
            }]
        }
    }

    // MARK: Index

    @Test func pathsCompose() {
        let root = nestedFixture()
        let index = TreeQuery.Index(root: root, rootPath: "/scan")
        let deep = index.node(at: "/scan/app/node_modules/nested")
        #expect(deep != nil)
        #expect(index.path(of: deep!) == "/scan/app/node_modules/nested")
        #expect(index.path(of: root) == "/scan")
    }

    @Test func rootAtSlashDoesNotDoubleUpSeparators() {
        let root = branch("/", in: nil) { r in [leaf("Users", in: r, bytes: 10)] }
        let index = TreeQuery.Index(root: root, rootPath: "/")
        #expect(index.path(of: root.children[0]) == "/Users")
        #expect(index.node(at: "/Users") === root.children[0])
    }

    @Test func pathsOutsideTheScanDoNotResolve() {
        let index = TreeQuery.Index(root: nestedFixture(), rootPath: "/scan")
        // The fence is what stops the server becoming an arbitrary filesystem
        // reader, and what stops a mistyped path silently triggering a re-scan.
        #expect(index.node(at: "/etc/passwd") == nil)
        #expect(index.node(at: "/scanner/other") == nil) // prefix that isn't a path prefix
        #expect(index.node(at: "/scan/app/missing") == nil)
    }

    @Test func relativeAndTrailingSlashPathsResolve() {
        let index = TreeQuery.Index(root: nestedFixture(), rootPath: "/scan")
        #expect(index.node(at: "app")?.name == "app")
        #expect(index.node(at: "/scan/app/")?.name == "app")
        #expect(index.node(at: "")  === index.root)
    }

    // MARK: find

    @Test func findDoesNotDescendIntoItsOwnMatches() {
        // The inner node_modules lives inside the outer one. Counting both would
        // double its bytes in the total — and that total is the whole point.
        let index = TreeQuery.Index(root: nestedFixture(), rootPath: "/scan")
        let hits = TreeQuery.find(in: index.root, pattern: "node_modules")
        #expect(hits.count == 1)
        #expect(hits[0].sizeOnDisk == 1000)
        #expect(index.path(of: hits[0]) == "/scan/app/node_modules")
    }

    @Test func findGlobsAndFiltersBySize() {
        let root = branch("root", in: nil) { r in
            [leaf("a.xcodeproj", in: r, bytes: 500), leaf("b.xcodeproj", in: r, bytes: 5),
             leaf("notes", in: r, bytes: 900)]
        }
        #expect(TreeQuery.find(in: root, pattern: "*.xcodeproj").count == 2)
        #expect(TreeQuery.find(in: root, pattern: "*.xcodeproj", minBytes: 100).count == 1)
        #expect(TreeQuery.find(in: root, pattern: "root").isEmpty) // the root is never its own match
    }

    // MARK: aged

    @Test func agedReportsTheOutermostColdFolderOnly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let root = branch("root", in: nil) { r in
            [branch("stale", in: r) { s in [leaf("inner", in: s, bytes: 1000)] },
             leaf("fresh", in: r, bytes: 1000)]
        }
        let stale = root.children.first { $0.name == "stale" }!
        let old = Int64(now.timeIntervalSince1970 - 800 * 86_400)
        stale.raiseNewestMTime(old)
        stale.children[0].raiseNewestMTime(old)
        root.children.first { $0.name == "fresh" }!
            .raiseNewestMTime(Int64(now.timeIntervalSince1970 - 3 * 86_400))

        let hits = TreeQuery.aged(in: root, olderThanDays: 365, minBytes: 0, now: now)
        // `inner` is cold too, but saying so adds nothing once its parent is named.
        #expect(hits.count == 1)
        #expect(hits[0].name == "stale")
    }

    @Test func agedIgnoresUnknownTimestamps() {
        // A streamed scan has none. Treating 0 as 1970 would report the entire
        // tree as ancient, which is the exact inverse of useful.
        let root = branch("root", in: nil) { r in [leaf("a", in: r, bytes: 1000)] }
        #expect(TreeQuery.aged(in: root, olderThanDays: 1, minBytes: 0).isEmpty)
    }

    // MARK: top

    @Test func topRanksTheWholeSubtreeNotJustDirectChildren() {
        let root = branch("root", in: nil) { r in
            [branch("mid", in: r) { m in [leaf("deep", in: m, bytes: 900)] },
             leaf("shallow", in: r, bytes: 100)]
        }
        let rows = TreeQuery.top(of: root, limit: 10)
        #expect(rows.map(\.name) == ["mid", "deep", "shallow"])
        #expect(!rows.contains { $0 === root })
        #expect(TreeQuery.top(of: root, limit: 10, minBytes: 500).map(\.name) == ["mid", "deep"])
    }

    // MARK: Parsing

    @Test(arguments: [
        ("1024", Int64(1024)), ("1k", 1024), ("10MB", 10 << 20), ("2GiB", 2 << 30),
        ("1.5g", Int64(1.5 * 1024 * 1024 * 1024)), ("0", 0),
    ])
    func sizesParse(input: String, expected: Int64) {
        #expect(TreeQuery.parseBytes(input) == expected)
    }

    @Test(arguments: ["", "abc", "10QB", "-5"])
    func badSizesAreRejected(input: String) {
        #expect(TreeQuery.parseBytes(input) == nil)
    }

    @Test func durationsParse() {
        #expect(TreeQuery.parseDays("90d") == 90)
        #expect(TreeQuery.parseDays("2w") == 14)
        #expect(TreeQuery.parseDays("1y") == 365.25)
        // "m" is months, not minutes: nothing here is measured in minutes.
        #expect(TreeQuery.parseDays("6m") == TreeQuery.parseDays("6mo"))
        #expect(TreeQuery.parseDays("soon") == nil)
    }
}
