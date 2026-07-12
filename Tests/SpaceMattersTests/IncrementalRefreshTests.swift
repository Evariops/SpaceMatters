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

    static func lossy(_ path: String) -> FSChange {
        FSChange(path: path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs))
    }

    /// Pump the run loop + yield until `cond` holds (the silent reconciler runs
    /// as MainActor tasks — it needs the actor to breathe).
    static func waitUntil(timeout: TimeInterval = 5, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
    }

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

    // MARK: Structural diffs (M2 — additive attach/detach)

    /// A new subdirectory (with nested content) is attached by mini-scanning
    /// only the new content: existing children keep their identity, totals and
    /// folder count reconcile exactly, and the brand-new extension shows up in
    /// File-types (exact merge — nothing of it was booked before).
    @Test func appearedSubdirectoryIsAttachedAdditively() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await Self.scanned(root)
        let beta = try #require(NavigationTests.child(c.root!, "beta"))
        let alpha = try #require(NavigationTests.child(c.root!, "alpha"))
        let rootLogBefore = c.root!.aggLogical.load(ordering: .relaxed)
        let dirsBefore = c.dirCount
        #expect(c.extRows.first { $0.name == ".zzz" } == nil)

        let nest = root.appendingPathComponent("beta/fresh/nested")
        try FileManager.default.createDirectory(at: nest, withIntermediateDirectories: true)
        try Data(count: 32768).write(to: nest.appendingPathComponent("n.zzz"))
        try Data(count: 4096).write(to: root.appendingPathComponent("beta/fresh/f.zzz"))

        #expect(await c.restatDirectory(beta))

        #expect(NavigationTests.child(c.root!, "beta") === beta)   // no rebuild
        #expect(NavigationTests.child(c.root!, "alpha") === alpha)
        let fresh = try #require(NavigationTests.child(beta, "fresh"))
        #expect(fresh.aggLogical.load(ordering: .relaxed) == 32768 + 4096)
        #expect(c.root!.aggLogical.load(ordering: .relaxed) == rootLogBefore + 32768 + 4096)
        #expect(c.dirCount == dirsBefore + 2)                      // fresh + nested
        #expect(c.extRows.first { $0.name == ".zzz" }?.count == 2)
    }

    /// A subdirectory deleted on disk is subtracted and detached — and any
    /// navigation state pointing into it is lifted to the surviving parent.
    @Test func disappearedSubdirectoryIsDetached() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await Self.scanned(root)
        let alpha = try #require(NavigationTests.child(c.root!, "alpha"))
        let deep = try #require(NavigationTests.child(alpha, "deep"))
        c.zoom(into: deep)
        let rootLogBefore = c.root!.aggLogical.load(ordering: .relaxed)
        let dirsBefore = c.dirCount

        try FileManager.default.removeItem(at: root.appendingPathComponent("alpha/deep"))
        #expect(await c.restatDirectory(alpha))

        #expect(NavigationTests.child(alpha, "deep") == nil)
        #expect(c.root!.aggLogical.load(ordering: .relaxed) == rootLogBefore - 8192)
        #expect(c.dirCount == dirsBefore - 1)
        #expect(c.zoomRoot === alpha)   // lifted out of the freed subtree
        #expect(NavigationTests.child(c.root!, "alpha") === alpha)
    }

    /// A rename is one disappearance + one appearance under the same parent:
    /// the totals are conserved, the new name carries the old content.
    @Test func renameLandsAsDisappearPlusAppear() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await Self.scanned(root)
        let rootLogBefore = c.root!.aggLogical.load(ordering: .relaxed)

        try FileManager.default.moveItem(
            at: root.appendingPathComponent("beta"),
            to: root.appendingPathComponent("gamma"))
        #expect(await c.restatDirectory(c.root!))

        #expect(NavigationTests.child(c.root!, "beta") == nil)
        let gamma = try #require(NavigationTests.child(c.root!, "gamma"))
        #expect(gamma.aggLogical.load(ordering: .relaxed) == 4096)
        #expect(c.root!.aggLogical.load(ordering: .relaxed) == rootLogBefore)
    }

    /// A change in a directory created *after* the scan maps to the nearest
    /// existing ancestor; its re-stat discovers the appeared chain (a direct
    /// child, by construction) and the mini-scan covers the rest of the depth.
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
        #expect(NavigationTests.child(c.root!, "beta") === beta) // additive, no rebuild
        let new1 = try #require(NavigationTests.child(beta, "new1"))
        #expect(NavigationTests.child(new1, "new2") != nil)
    }

    // MARK: Live reconciliation (M3 — the default)

    /// The core promise: a change lands in the map with *no click at all*. A
    /// forged precise event reconciles silently — no banner, no rebuild.
    @Test func preciseEventReconcilesAutomatically() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await Self.scanned(root)
        let alpha = try #require(NavigationTests.child(c.root!, "alpha"))
        let alphaLogBefore = alpha.aggLogical.load(ordering: .relaxed)

        try Data(count: 262_144).write(to: root.appendingPathComponent("alpha/live.dat"))
        c.handleDiskChanges([Self.precise(root.appendingPathComponent("alpha").path)])

        await Self.waitUntil { alpha.aggLogical.load(ordering: .relaxed) == alphaLogBefore + 262_144 }
        #expect(alpha.aggLogical.load(ordering: .relaxed) == alphaLogBefore + 262_144)
        #expect(c.autoRestatCount >= 1)
        #expect(!c.diskChanged)                                  // silent
        #expect(!c.isRefreshing)                                 // no spinner either
        #expect(NavigationTests.child(c.root!, "alpha") === alpha)
    }

    /// A dense burst coalesces to *its own* ancestor (one parallel subtree
    /// pass), never to the global common ancestor — and scattered dirty paths
    /// nearby stay individual re-stats.
    @Test func denseBurstCoalescesToItsClusterAncestor() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mds-burst-\(UUID().uuidString)")
        for i in 0..<20 {
            try fm.createDirectory(at: root.appendingPathComponent("burst/d\(i)"), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: root.appendingPathComponent("calm"), withIntermediateDirectories: true)
        try Data(count: 4096).write(to: root.appendingPathComponent("calm/c.dat"))
        defer { try? fm.removeItem(at: root) }
        let c = await Self.scanned(root)

        // Touch every burst dir + the calm one, forge the whole batch at once.
        var changes: [FSChange] = []
        for i in 0..<20 {
            try Data(count: 4096).write(to: root.appendingPathComponent("burst/d\(i)/f.dat"))
            changes.append(Self.precise(root.appendingPathComponent("burst/d\(i)").path))
        }
        try Data(count: 8192).write(to: root.appendingPathComponent("calm/c2.dat"))
        changes.append(Self.precise(root.appendingPathComponent("calm").path))
        c.handleDiskChanges(changes)

        let burst = try #require(NavigationTests.child(c.root!, "burst"))
        let calm = try #require(NavigationTests.child(c.root!, "calm"))
        await Self.waitUntil {
            burst.aggLogical.load(ordering: .relaxed) == 20 * 4096
                && calm.aggLogical.load(ordering: .relaxed) == 4096 + 8192
        }
        #expect(burst.aggLogical.load(ordering: .relaxed) == 20 * 4096)
        #expect(calm.aggLogical.load(ordering: .relaxed) == 4096 + 8192)
        #expect(c.autoSubtreeScanCount == 1)   // the cluster, as ONE pass
        #expect(c.autoRestatCount == 1)        // calm stayed individual
        #expect(!c.diskChanged)
    }

    /// Sustained churn on one subtree: the second `MustScanSubDirs` within the
    /// cooldown window is deferred (stays dirty), not re-scanned immediately.
    @Test func cooldownAbsorbsRepeatedSubtreeChurn() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await Self.scanned(root)
        let alphaPath = root.appendingPathComponent("alpha").path

        c.handleDiskChanges([Self.lossy(alphaPath)])
        await Self.waitUntil { c.autoSubtreeScanCount == 1 }
        #expect(c.autoSubtreeScanCount == 1)

        c.handleDiskChanges([Self.lossy(alphaPath)])
        // Give the reconciler ample room to (wrongly) run a second pass.
        try await Task.sleep(for: .milliseconds(300))
        await Task.yield()
        #expect(c.autoSubtreeScanCount == 1)             // absorbed by cooldown
        #expect(!c.dirtyPaths.isEmpty)                   // still marked, not lost
    }

    /// Above the consent threshold the catch-up parks and lights the banner;
    /// pressing Refresh (the consent) runs it and clears everything.
    @Test func oversizeCatchupWaitsForConsent() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await Self.scanned(root)
        c.consentMaxFiles = 1 // alpha subtree holds 2 files — over the bar
        let alpha = try #require(NavigationTests.child(c.root!, "alpha"))
        let deep = try #require(NavigationTests.child(alpha, "deep"))

        try Data(count: 65536).write(to: root.appendingPathComponent("alpha/big.dat"))
        c.handleDiskChanges([Self.lossy(root.appendingPathComponent("alpha").path)])

        await Self.waitUntil { c.diskChanged }
        #expect(c.diskChanged)                           // banner asks
        #expect(c.autoSubtreeScanCount == 0)             // nothing ran silently
        #expect(c.pendingConsentFiles >= 2)
        #expect(NavigationTests.child(alpha, "deep") === deep) // untouched

        await c.refreshDirty()                           // consent
        #expect(!c.diskChanged)
        #expect(c.pendingConsentPaths.isEmpty)
        #expect(alpha.aggLogical.load(ordering: .relaxed) == 4096 + 8192 + 65536)
    }

    // MARK: File-types & drift accounting (M4)

    /// Without an old per-extension table the first delta marks the drift and
    /// leaves the panel alone; the re-stat stores the directory's table, so the
    /// *second* delta diffs exactly — and heals the first one's gap in passing.
    @Test func fileTypesDiffExactlyFromSecondDeltaOn() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await Self.scanned(root)
        let beta = try #require(NavigationTests.child(c.root!, "beta"))
        #expect(!c.typesDrifted)

        // First delta: no stored table, no cached listing → drift, no panel touch.
        try Data(count: 4096).write(to: root.appendingPathComponent("beta/one.png"))
        #expect(await c.restatDirectory(beta))
        #expect(c.typesDrifted)
        #expect(c.extRows.first { $0.name == ".png" } == nil)

        // Second delta: diffs against the stored table → exact, including the
        // .png the first pass couldn't book.
        try Data(count: 4096).write(to: root.appendingPathComponent("beta/two.png"))
        #expect(await c.restatDirectory(beta))
        #expect(c.extRows.first { $0.name == ".png" }?.count == 2)
        #expect(c.extRows.first { $0.name == ".dat" }?.count == 3) // untouched
    }

    /// When the outline already holds the directory's complete listing, even
    /// the first delta diffs exactly — no drift at all.
    @Test func fileTypesExactWhenListingWasCached() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await Self.scanned(root)
        let beta = try #require(NavigationTests.child(c.root!, "beta"))

        _ = c.filesIn(beta) // kicks the async listing
        await Self.waitUntil { !c.filesIn(beta).isEmpty }
        #expect(!c.filesIn(beta).isEmpty)

        try Data(count: 4096).write(to: root.appendingPathComponent("beta/first.png"))
        #expect(await c.restatDirectory(beta))
        #expect(c.extRows.first { $0.name == ".png" }?.count == 1)
        #expect(!c.typesDrifted)
    }

    /// `changedBytes` is the exact sum of applied physical deltas — and the
    /// consented refresh restarts the accounting.
    @Test func changedBytesTracksAppliedDeltasExactly() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await Self.scanned(root)
        let beta = try #require(NavigationTests.child(c.root!, "beta"))
        #expect(c.changedBytes == 0)
        let physBefore = beta.aggPhysical.load(ordering: .relaxed)

        try Data(count: 262_144).write(to: root.appendingPathComponent("beta/blob.bin"))
        #expect(await c.restatDirectory(beta))
        let applied = beta.aggPhysical.load(ordering: .relaxed) - physBefore
        #expect(applied >= 262_144)
        #expect(c.changedBytes == applied)

        try FileManager.default.removeItem(at: root.appendingPathComponent("beta/blob.bin"))
        #expect(await c.restatDirectory(beta))
        #expect(c.changedBytes == 0) // grew then shrank — net zero, exactly

        await c.refreshDirty()
        #expect(c.changedBytes == 0)
    }

    /// Exact counting mode: a reconciled directory holding hardlinked files
    /// raises the dedup-drift marker (their bytes were attributed locally).
    @Test func exactModeMarksHardlinkDrift() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = await Self.scanned(root)
        c.countingMode = .exact       // triggers a rescan with dedup semantics
        await NavigationTests.waitForScan(c)
        let beta = try #require(NavigationTests.child(c.root!, "beta"))
        #expect(!c.exactDrifted)

        try FileManager.default.linkItem(
            at: root.appendingPathComponent("beta/b.dat"),
            to: root.appendingPathComponent("beta/b-link.dat"))
        #expect(await c.restatDirectory(beta))
        #expect(c.exactDrifted)
    }

    // MARK: Planner (pure)

    /// Clustering policy on synthetic paths: a dense run coalesces to its own
    /// ancestor, scattered paths stay individual, an oversized target needs
    /// consent, a cooling-down target is deferred.
    @Test func plannerClustersCapsAndDefers() throws {
        var needs: [String: ScanController.DirtyNeed] = [:]
        for i in 0..<20 { needs["/seed/dense/d\(i)"] = .restat }
        needs["/seed/lonely"] = .restat
        needs["/seed/other/spot"] = .restat
        needs["/seed/huge"] = .subtree      // MustScanSubDirs, over consent
        needs["/seed/cooling"] = .subtree   // recently auto-scanned

        let fileCounts: [String: Int64] = [
            "/seed/dense": 500, "/seed/huge": 1_000_000, "/seed/cooling": 10,
            "/seed": 2_000_000,
        ]
        let plan = ScanController.planReconciliation(
            needs: needs,
            fileCount: { fileCounts[$0] },
            underCooldown: { $0 == "/seed/cooling" },
            clusterMinRun: 16,
            subtreeAutoMaxFiles: 100_000,
            consentMaxFiles: 500_000,
            restatCap: 256
        )
        #expect(plan.subtrees == ["/seed/dense"])
        #expect(Set(plan.restats) == ["/seed/lonely", "/seed/other/spot"])
        #expect(plan.consent == ["/seed/huge"])
        #expect(plan.deferred == ["/seed/cooling"])
    }

    /// The cap bounds one cycle's precise work; the spill stays for the next.
    @Test func plannerCapsRestatsPerCycle() throws {
        var needs: [String: ScanController.DirtyNeed] = [:]
        for i in 0..<10 { needs["/seed/s\(i)"] = .restat }
        let plan = ScanController.planReconciliation(
            needs: needs, fileCount: { _ in nil }, underCooldown: { _ in false },
            clusterMinRun: 16, subtreeAutoMaxFiles: 100_000,
            consentMaxFiles: 500_000, restatCap: 4)
        #expect(plan.restats.count == 4)
        #expect(plan.deferred.count == 6)
        #expect(plan.subtrees.isEmpty && plan.consent.isEmpty)
    }

    // MARK: Live QA at scale (opt-in)

    /// Replays the 2026-07-12 finding at real scale (opt-in: `SM_QA_LIVE=1`):
    /// scan a big working tree, then land a 512 MiB file in a brand-new
    /// directory. It must appear in the totals **without any user action**
    /// within the FSEvents latency (~1 s) + milliseconds of reconcile — against
    /// the 25 s + a click the old subtree refresh cost. Then deletion melts it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SM_QA_LIVE"] != nil))
    func liveReconcileAtScale() async throws {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("sources")
        let qaDir = base.appendingPathComponent("__sm_qa_live__")
        try? fm.removeItem(at: qaDir) // leftovers from a crashed run
        defer { try? fm.removeItem(at: qaDir) }

        let c = ScanController()
        c.scan(url: base)
        await NavigationTests.waitForScan(c, timeout: 300)
        #expect(c.phase == .finished)
        let physBefore = c.root!.aggPhysical.load(ordering: .relaxed)
        let size = 512 * 1024 * 1024

        try fm.createDirectory(at: qaDir, withIntermediateDirectories: true)
        try Data(count: size).write(to: qaDir.appendingPathComponent("blob.bin"))
        let t0 = Date()
        await Self.waitUntil(timeout: 10) {
            c.root!.aggPhysical.load(ordering: .relaxed) >= physBefore + Int64(size)
        }
        let appearLatency = Date().timeIntervalSince(t0)
        print("QA live: +512 MiB reconciled in \(String(format: "%.2f", appearLatency))s after write")
        #expect(c.root!.aggPhysical.load(ordering: .relaxed) >= physBefore + Int64(size))
        #expect(appearLatency < 3) // ~1 s FSEvents latency + reconcile
        #expect(!c.diskChanged)    // silent — no banner at any point
        #expect(!c.isRefreshing)

        try fm.removeItem(at: qaDir)
        let t1 = Date()
        await Self.waitUntil(timeout: 10) {
            c.root!.aggPhysical.load(ordering: .relaxed) < physBefore + Int64(size) / 2
        }
        let meltLatency = Date().timeIntervalSince(t1)
        print("QA live: deletion melted in \(String(format: "%.2f", meltLatency))s")
        #expect(meltLatency < 3)
        #expect(!c.diskChanged)
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
