import Testing
import Foundation
@testable import SpaceMatters

/// SPEC-11: per-directory incremental refresh. These drive a real
/// `ScanController` over a real scanned tree and forge FSEvents batches
/// directly into `handleDiskChanges` — no FSEvents latency, no GUI.
@MainActor
@Suite struct IncrementalRefreshTests {

    /// root/{alpha,alpha/deep,beta}, files in each.
    static func makeFixture() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mds-inc-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("alpha/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("beta"), withIntermediateDirectories: true)
        try Data(count: 4096).write(to: root.appendingPathComponent("alpha/a.dat"))
        try Data(count: 8192).write(to: root.appendingPathComponent("alpha/deep/d.dat"))
        try Data(count: 4096).write(to: root.appendingPathComponent("beta/b.dat"))
        return root
    }

    static func scanned(_ root: URL) async -> ScanController {
        let c = ScanController()
        c.scan(url: root)
        await NavigationTests.waitForScan(c)
        return c
    }

    static func precise(_ path: String) -> FSChange { FSChange(path: path, flags: 0) }

    // MARK: Re-stat: pure file deltas, no sub-scan

    /// A file grows in an already-scanned directory: one re-stat propagates the
    /// exact delta to every ancestor — and the subtree's nodes keep their
    /// identity (the signature that no rebuild/sub-scan happened).
    @Test func restatPropagatesExactFileDeltaWithoutRebuilding() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await Self.scanned(root)

        let alpha = try #require(NavigationTests.child(c.root!, "alpha"))
        let deep = try #require(NavigationTests.child(alpha, "deep"))
        let rootPhysBefore = c.root!.aggPhysical.load(ordering: .relaxed)
        let alphaLogBefore = alpha.aggLogical.load(ordering: .relaxed)

        // 64 KiB rewrite of a.dat (4 KiB → 64 KiB) + a brand-new sibling file.
        try Data(count: 65536).write(to: root.appendingPathComponent("alpha/a.dat"))
        try Data(count: 4096).write(to: root.appendingPathComponent("alpha/a2.dat"))

        let ok = await c.restatDirectory(alpha)
        #expect(ok)

        // Logical deltas are byte-exact: +60 KiB (rewrite) +4 KiB (new file).
        #expect(alpha.aggLogical.load(ordering: .relaxed) == alphaLogBefore + 61440 + 4096)
        #expect(alpha.directFileCount == 2)
        #expect(c.root!.aggPhysical.load(ordering: .relaxed) > rootPhysBefore)
        #expect(c.totalLogical == c.root!.aggLogical.load(ordering: .relaxed))
        // No rebuild: same node objects before and after.
        #expect(NavigationTests.child(c.root!, "alpha") === alpha)
        #expect(NavigationTests.child(alpha, "deep") === deep)
    }

    /// Deleting a file is a negative delta — same path, exact subtraction.
    @Test func restatSubtractsDeletedFiles() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await Self.scanned(root)

        let beta = try #require(NavigationTests.child(c.root!, "beta"))
        let rootLogBefore = c.root!.aggLogical.load(ordering: .relaxed)

        try FileManager.default.removeItem(at: root.appendingPathComponent("beta/b.dat"))
        #expect(await c.restatDirectory(beta))

        #expect(beta.directFileCount == 0)
        #expect(beta.aggLogical.load(ordering: .relaxed) == 0)
        #expect(c.root!.aggLogical.load(ordering: .relaxed) == rootLogBefore - 4096)
    }

    /// The re-stat's listing refreshes the outline's file cache in place: the
    /// new file shows up in `filesIn` without any extra disk walk.
    @Test func restatRefreshesFileListing() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await Self.scanned(root)

        let beta = try #require(NavigationTests.child(c.root!, "beta"))
        try Data(count: 123_456).write(to: root.appendingPathComponent("beta/fresh.dat"))
        #expect(await c.restatDirectory(beta))

        let names = c.filesIn(beta).map(\.name)
        #expect(names.contains("fresh.dat"))
        #expect(names.contains("b.dat"))
    }

    // MARK: Event classification

    /// A forged precise FSEvents batch marks the exact directory dirty with
    /// `.restat`; `refreshDirty` then reconciles it without rebuilding nodes.
    @Test func preciseEventLeadsToRestatOnRefresh() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await Self.scanned(root)
        let alpha = try #require(NavigationTests.child(c.root!, "alpha"))

        try Data(count: 32768).write(to: root.appendingPathComponent("alpha/n.dat"))
        c.handleDiskChanges([Self.precise(root.appendingPathComponent("alpha").path)])
        let alphaPath = try #require(c.path(for: alpha))
        #expect(c.dirtyPaths.contains(alphaPath))
        #expect(c.dirtyNeeds[alphaPath] == .restat)

        await c.refreshDirty()
        // NB: no `dirtyPaths.isEmpty` assert — the *real* FSWatcher also runs on
        // this temp dir and its echo of our write may legitimately re-mark it.
        #expect(alpha.directFileCount == 2)
        // Identity preserved — the precise path never went through invalidate.
        #expect(NavigationTests.child(c.root!, "alpha") === alpha)
    }

    /// `MustScanSubDirs` (kernel coalesced events away) forces the subtree
    /// re-scan — nodes are rebuilt — and is sticky against later precise events.
    @Test func mustScanSubDirsForcesSubtreeRescan() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await Self.scanned(root)
        let alpha = try #require(NavigationTests.child(c.root!, "alpha"))
        let deep = try #require(NavigationTests.child(alpha, "deep"))
        let alphaPath = try #require(c.path(for: alpha))

        // Change *deep* under alpha, but report it at alpha with detail lost.
        try Data(count: 65536).write(to: root.appendingPathComponent("alpha/deep/extra.dat"))
        let lossy = FSChange(
            path: alphaPath,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs))
        c.handleDiskChanges([lossy])
        c.handleDiskChanges([Self.precise(alphaPath)]) // must not downgrade
        #expect(c.dirtyNeeds[alphaPath] == .subtree)

        await c.refreshDirty()
        // `invalidate` re-scans *in place*: alpha keeps its identity, its
        // descendants are rebuilt as fresh objects — the subtree pass signature.
        let alphaAfter = try #require(NavigationTests.child(c.root!, "alpha"))
        #expect(alphaAfter === alpha)
        #expect(NavigationTests.child(alphaAfter, "deep") !== deep)
        #expect(alphaAfter.aggLogical.load(ordering: .relaxed)
            == 4096 + 8192 + 65536)
    }

    /// A change in a directory created *after* the scan maps to the nearest
    /// existing ancestor; its re-stat discovers the appeared chain and the
    /// totals converge (M1 routes structural diffs through the subtree pass).
    @Test func unknownDeepPathConvergesViaNearestAncestor() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await Self.scanned(root)
        let beta = try #require(NavigationTests.child(c.root!, "beta"))
        let rootLogBefore = c.root!.aggLogical.load(ordering: .relaxed)

        // New chain beta/new1/new2 with a file, event reported on the deep dir.
        let deepNew = root.appendingPathComponent("beta/new1/new2")
        try FileManager.default.createDirectory(at: deepNew, withIntermediateDirectories: true)
        try Data(count: 16384).write(to: deepNew.appendingPathComponent("x.dat"))
        c.handleDiskChanges([Self.precise(deepNew.path)])
        let betaPath = try #require(c.path(for: beta))
        #expect(c.dirtyPaths.contains(betaPath)) // mapped to nearest existing node

        await c.refreshDirty()
        #expect(c.root!.aggLogical.load(ordering: .relaxed) == rootLogBefore + 16384)
        let betaAfter = try #require(NavigationTests.child(c.root!, "beta"))
        let new1 = try #require(NavigationTests.child(betaAfter, "new1"))
        #expect(NavigationTests.child(new1, "new2") != nil)
    }

    /// A `.subtree` ancestor subsumes its dirty descendants; a `.restat`
    /// ancestor subsumes nothing (it's non-recursive) — both children survive.
    @Test func subsumptionFollowsNeedSemantics() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await Self.scanned(root)
        let alpha = try #require(NavigationTests.child(c.root!, "alpha"))
        let deep = try #require(NavigationTests.child(alpha, "deep"))
        let alphaPath = try #require(c.path(for: alpha))
        let deepPath = try #require(c.path(for: deep))

        // Precise events on parent AND child: both re-stats must run (the
        // parent's pass doesn't see the child's own files).
        try Data(count: 4096).write(to: root.appendingPathComponent("alpha/p.dat"))
        try Data(count: 4096).write(to: root.appendingPathComponent("alpha/deep/q.dat"))
        c.handleDiskChanges([Self.precise(alphaPath), Self.precise(deepPath)])
        await c.refreshDirty()
        #expect(alpha.directFileCount == 2)      // a.dat + p.dat
        #expect(deep.directFileCount == 2)       // d.dat + q.dat
        #expect(NavigationTests.child(alpha, "deep") === deep) // still no rebuild
    }
}
