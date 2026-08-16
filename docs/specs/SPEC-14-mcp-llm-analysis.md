# SPEC-14 — LLM analysis: token-budgeted digests, an MCP server, and verdicts painted back onto the map

> **Request**: let a Claude session do a *detailed* analysis of a scan. The app cannot spawn the session itself (`claude -p` is API-token-only, so subscription users have no headless path), so the flow inverts: **the user starts the session, and the session calls the app**.
> **Status**: 🟢 **Phases 0–3 implemented** (branch `feat/llm-briefing`) — [TreeDigest](../../Sources/SpaceMatters/Model/TreeDigest.swift), the ⌘⇧C briefing, `ATTR_CMN_MODTIME` with max-propagated watermarks, [TreeQuery](../../Sources/SpaceMatters/Model/TreeQuery.swift), a read-only MCP server behind `--mcp` that attaches to the running app when it can, and verdicts painted onto both maps. Phase 4 (skill + one-click setup) remains specified only.
> **Guiding constraint**: the scanner measures, the LLM classifies. Everything here exists to hand a model the smallest payload that still supports a correct verdict — and to bring that verdict back into the map, where the user already is.

## 0. Phase 0 implementation result

- **[TreeDigest](../../Sources/SpaceMatters/Model/TreeDigest.swift)** — greedy size-ordered expansion under a hard line budget, single-child chain collapsing, own-files block ranked against sub-folders, `[+ n smaller folders]` rollup, `cache:<id>` / `sparse` / `~.ext` annotations, name sanitisation. Pure over `FSNode` + scalars; no AppKit, no MainActor.
- **⌘⇧C "Copy LLM Briefing"** — [ScanController.llmBriefing()](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L753) / `copyLLMBriefing()`, [AppModel.copyBriefing()](../../Sources/SpaceMatters/ViewModel/AppModel.swift), Edit-menu item in [SpaceMattersApp](../../Sources/SpaceMatters/App/SpaceMattersApp.swift). Digests the **zoom root**, and withholds the scan-wide counters and file-type table when scoped to a subtree rather than showing them against the wrong denominator.
- **Added beyond the plan**: `SpaceMatters --briefing <path> [max-nodes]` ([HeadlessScan.runBriefing](../../Sources/SpaceMatters/App/HeadlessScan.swift#L85)). Without it the digest is only observable by driving the GUI, which makes it untestable on a real disk — and it is the entry point phase 2 grows out of.
- **Decided during implementation**: a folder with no sub-folders does **not** print an `[n files here]` line. Its size line already states those bytes, and leaves are the most numerous node kind — the rule alone freed a large fraction of the budget on real trees.
- **Measured**: `~/Library/Application Support` (35,5 GiB, 198 k files) at `maxNodes: 200` → 199 tree lines, 226 total, ~1 170 words ≈ 2,5–3 k tokens. At `maxNodes: 60` → exactly 60 tree lines.
- **Tests**: 17 in [TreeDigestTests](../../Tests/SpaceMattersTests/TreeDigestTests.swift); full suite **141 green**. Live-verified end to end: the Edit-menu item exists, clicking it via System Events puts a 307-line briefing on the pasteboard.

## 0b. Phase 1 implementation result

- **`ATTR_CMN_MODTIME`** ([FSAttr](../../Sources/SpaceMatters/Scanner/FSAttr.swift#L16)) parsed between `OBJTYPE` and `FLAGS` as a whole `timespec`; `BulkEntry.modTime` in unix seconds, **`0` = unknown, never 1970**. `FSNode.newestMTime` is max-propagated up the ancestor chain by a CAS loop ([raiseNewestMTime](../../Sources/SpaceMatters/Model/FSNode.swift)) on the same walk that sum-propagates sizes. Directory mtimes are deliberately excluded — they move on any entry add/remove, which would make nearly every folder read as warm (test: `directoryMTimesAreIgnored`).
- **`cold:8mo` / `cold:3y`** in the digest, **inherited rather than repeated**: watermarks are max-propagated so a child is always at least as cold as its parent, and re-stating the parent's bucket on every nested line costs a token and says nothing. A child that is *older* still earns its own mark.
- **Cost: none measurable.** Same attribute list, same syscall. `~/Library/Application Support` (198 k files), 3 runs each against the pre-change build: base 1,38–1,43 s, with mtime 1,23–1,47 s — inside the noise. The cold annotations add ~60 words to a 200-node briefing (1 172 → 1 232).
- **Accuracy cross-checked against the filesystem**, which is what would catch a wrong parse offset that the golden tests can't see: `find -exec stat` on three real subtrees gives 180 / 313 / 529 days, the digest prints `cold:6mo` / `cold:10mo` / `cold:17mo`. Exact.
- **The per-subtree extension rollup planned in §4 step 4 turned out to be impossible as specified** — see the correction there. `TreeQuery.approximateTypes` reconstructs it from per-directory dominant types instead, labelled as an estimate wherever it is shown. Validated against the exact scan-wide table on a real 35 GiB tree: **top-10 overlap 10/10**, sizes within a few percent, minor rank shuffling in the 5–10 band (`.vscdb` over-credited 634 MiB → 979 MiB — precisely the predicted mixed-folder bias).
- **Tests**: 6 in [ModTimeTests](../../Tests/SpaceMattersTests/ModTimeTests.swift) + 6 more in `TreeDigestTests`; full suite **153 green**.

## 0c. Phase 2 implementation result

**The TCC measurement came first, as §6 demanded — and it did not go the way the spec assumed.**

| context | reading `~/Library/Safari` |
|---|---|
| the shell Claude Code runs commands in | denied |
| raw `.build/debug` binary spawned from it | denied, 1 skipped |
| **bundled** `/Applications/SpaceMatters.app` binary spawned from it | denied, 1 skipped |
| the same bundle launched by **LaunchServices** (`open`) | **denied too** — 0 B, 0 files, 1 skipped |

Full Disk Access is simply **not granted to SpaceMatters on this machine**, which makes the *transfer* question (does a bundle's grant follow a spawned binary?) undecidable here — but also moot for shipping: the user already runs the GUI without it, and the 466 skipped entries in their own full-disk scan are that fact's signature. Detached mode is no blinder than the app they use today. What the finding does mandate is that the denial be **reported**, and the app already owns a better detector than the ratio heuristic §6 proposed — [FullDiskAccess.isGranted](../../Sources/SpaceMatters/Util/FullDiskAccess.swift), which probes `open()` on FDA-gated paths. Used instead.

- **[JSONRPC](../../Sources/SpaceMatters/App/MCP/JSONRPC.swift)** — newline-delimited JSON-RPC 2.0 on stdio, ~110 lines, no dependency. stdout is the wire, so every diagnostic goes to stderr; a malformed line is logged and skipped rather than ending the loop.
- **[MCPServer](../../Sources/SpaceMatters/App/MCP/MCPServer.swift)** — `initialize` / `tools/list` / `tools/call` / `ping`, the eight read-only tools of §3.3, lazy scan on first call held for the process lifetime. `initialize` echoes the client's `protocolVersion` (the server uses no version-specific feature, so agreeing beats asserting a build-time constant). Tool failures come back as `isError: true` results, not protocol errors, so the model sees them and corrects.
- **The access caveat is two-tier.** The full paragraph rides `overview` (which every session calls first); every other response carries one line. Repeating seventy words across twenty calls is exactly the waste the whole design exists to avoid.
- **`--mcp [path]` defaults to the home directory**, not `/`: that is where the actionable bytes are, and scanning `/` would spend the session's first minute on system files nobody may delete.
- **Measured, real session** — `overview` → `find node_modules` → `aged 1y` → `cleanup_targets` → `tree ~/Library`: scan of `$HOME` is **190 GiB / 1 904 295 files / 335 132 dirs in 13,6 s**, paid once; the five tool results total **1 527 words ≈ 2 100 tokens**, against §5's ≤ 15 k budget. `find` produced the finding the tool exists for: *19 `node_modules`, 6,67 GiB between them*, several marked `cold:6mo`.
- **Tests**: 8 in [MCPProtocolTests](../../Tests/SpaceMattersTests/MCPProtocolTests.swift) (parse survives garbage, string ids survive, every schema is valid and JSON-encodable, required keys are declared, no tool name reads as a mutation) + 14 in [TreeQueryTests](../../Tests/SpaceMattersTests/TreeQueryTests.swift) (the fence, nested-match dedup, outermost-cold-only, size/duration parsing). Full suite **172 green**.

## 0d. Phase 3 implementation result

**The payoff phase: the scanner measures, the model classifies, and the map is where they meet.**

- **Connected mode** — [MCPSocketServer](../../Sources/SpaceMatters/App/MCP/MCPSocketServer.swift) listens on `~/Library/Application Support/SpaceMatters/mcp.sock` (mode `0600`, opened only once a scan has finished so an attaching session always finds a tree), and [MCPRelay](../../Sources/SpaceMatters/App/MCP/MCPRelay.swift) makes `--mcp` try that socket first and fall back to a scan of its own. The user never chooses: one config line works with or without the app open, which is the only way an MCP entry can be reliable.
- **The tools were written once.** [MCPScanSource](../../Sources/SpaceMatters/App/MCP/MCPScanSource.swift) abstracts "a scan", `MCPServer.respond(to:)` returns the response object instead of writing it, and the two transports differ only in where that object goes. `annotate`/`focus` are advertised **only when an app is attached** — offering them against a standalone scan would earn the model an error per call.
- **The socket thread reads the tree directly.** Only the handle is taken on the main actor; the walk runs on the socket thread over `FSNode`, whose atomics and `gTreeLock` exist precisely so a reader outside the UI is safe. Mutations hop back to main.
- **Verdicts** — `safe` / `review` / `keep` with a **mandatory reason** (a colour is not an argument for deleting something; the sentence shows on hover). Stored by path on `ScanController`, re-resolved to nodes on every tree bump, inherited by descendants so marking a folder paints its region. The tint is blended *after* the palette LUT in both renderers, so a verdict never poisons the cached type colours, and it rides the existing highlight-repack path — a recolour, not a relayout.
- **Live-verified end to end.** App launched on this repo, session attached over the socket (`tools/list` returned all ten), three `annotate` calls accepted, a bad path refused with a usable message, `focus` selected the folder. Proof by A/B rather than by eye: mean colour of the map region was **(107, 158, 115)** with verdicts — a green bias of **+51** over red — and **(117, 120, 116)** after "Clear 3 LLM Verdicts", a bias of **+3**. Quitting the app removes the socket file.
- **A false alarm the smoke test exposed**: the access caveat fired on a scan where *nothing* had been denied, because it was gated on the FDA permission rather than on what happened. Now gated on `errors > 0` — crying wolf on a clean scoped scan teaches a model to ignore the warning on the scan where it matters.
- **Tests**: 7 in [VerdictTests](../../Tests/SpaceMattersTests/VerdictTests.swift) driving a real controller over a real scan (region inheritance, nearest-ancestor precedence, survival across `invalidate`, refusal outside the tree, clearing, distinct tints) + 2 more protocol tests. Full suite **181 green**.

## 1. Objective

Three deliverables, each useful alone, each reusing the one before it:

1. **`TreeDigest`** — a token-budgeted, hierarchy-preserving rendering of a scanned tree. 3.2 M files / 670 k directories must become ~3 k tokens without lying about the shape of the disk.
2. **An MCP stdio server** (`SpaceMatters --mcp`) exposing a read-only interrogation surface over a scan: overview, drill-down, ranking, pattern-aggregation, per-node explanation, cleanup catalog.
3. **The return channel** — `annotate(path, verdict, reason)` recolours the treemap and the sunburst by LLM verdict (safe / review / keep), and `focus(path)` drives the view. The map stays the interface; the model is a second opinion layered onto it, not a chat window bolted beside it.

Non-goals: no in-app chat, no bring-your-own-key, no network call of any kind (the README's "the only network request the app ever makes is the update feed" must remain true), and **no deletion tool in the MCP surface**.

## 2. Current state of the code (verified)

- **Headless entry point exists and is the natural host.** [Entry.main](../../Sources/SpaceMatters/App/SpaceMattersApp.swift#L8) already routes `--volumes`, `--containers`, `--k8s`, `--vm-scan`, `--scan` before `SpaceMattersApp.main()`. `--mcp` is one more branch. [HeadlessScan.run](../../Sources/SpaceMatters/App/HeadlessScan.swift#L12) shows the whole pattern: build an `FSNode` root, build `DirectoryScanner.Seed`s, `recommendedSkipPaths`, spin until `isFinished`, read atomics.
- **The GUI's tree accessor is MainActor-bound and cannot be reused headlessly.** [ScanController](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L10) is `@MainActor @Observable`; `path(for:)` ([ScanController.swift:731](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L731)) depends on its private `nodePaths` seed map ([:602](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L602)). So the digest layer must sit **below** the controller, on a bare `FSNode` root + seed map, and be consumed by both.
- **`FSNode` carries no path.** [FSNode](../../Sources/SpaceMatters/Model/FSNode.swift#L17) holds `name` + `unowned parent`; the absolute path is always rebuilt by walking to the nearest seed. Any digest that prints paths needs that walk, or must print relative paths (cheaper — see §3.2).
- **Sizes are atomics propagated up the ancestor chain**, `aggPhysical` / `aggLogical` / `fileCount` / `aggSparseExcess` / `aggCompressedExcess` ([FSNode.swift:26-35](../../Sources/SpaceMatters/Model/FSNode.swift#L26)). A max-propagated `newestMTime` would follow the exact same pattern (§3.4).
- **Semantic signal the app already owns, and `du` never will**: `dominantExt` per directory, [SizeDivergence](../../Sources/SpaceMatters/Model/FSNode.swift#L185) (sparse vs compressed, with user-facing prose already written), [CountingMode](../../Sources/SpaceMatters/Model/FSNode.swift#L237) attribution-vs-exact, the hand-picked [Cleanable catalog](../../Sources/SpaceMatters/Scanner/CleanupEngine.swift#L34) (18 targets with a `note` field stating what deleting costs), [NativeCleaner](../../Sources/SpaceMatters/Scanner/NativeCleaner.swift) requirements, and the [CleanupJournal](../../Sources/SpaceMatters/Util/CleanupJournal.swift) forensic trail.
- **What is missing: time.** [FSAttr](../../Sources/SpaceMatters/Scanner/FSAttr.swift#L9) requests `RETURNED_ATTRS | NAME | OBJTYPE | FLAGS | ERROR` (+ `DEVID | FILEID` in exact mode) and `TOTALSIZE | ALLOCSIZE`. **`ATTR_CMN_MODTIME` is not requested**, so `BulkEntry` ([FSAttr.swift:40](../../Sources/SpaceMatters/Scanner/FSAttr.swift#L40)) has no timestamp. Without it a model can identify regenerable data but never *cold* data — and "regenerable **and** untouched for a year" is the only delete signal strong enough to act on unprompted.
- **Extension rollup already exists** at the right shape: `snapshotExtensions(limit:)` → `[ExtRow]` ([DirectoryScanner.swift:175](../../Sources/SpaceMatters/Scanner/DirectoryScanner.swift#L175), [:396](../../Sources/SpaceMatters/Scanner/DirectoryScanner.swift#L396)), but it is **scanner-global**, not per-subtree. A subtree-scoped variant is needed (§3.3, `types` tool).

## 3. Design

### 3.1 `TreeDigest` — greedy size-ordered expansion under a node budget

The primitive everything else builds on. Naïve truncation (depth cap, or top-N children) either buries the interesting node under a shallow ceiling or drops the context that makes it interesting. Instead:

> Maintain a max-heap of *unexpanded* nodes keyed by `aggPhysical`. Seed it with the root. Pop the largest, expand it (its children become candidates, plus a synthetic **own-files** child so the arithmetic closes), and repeat until the node budget is spent or the heap empties. Render the expanded set as a tree; unexpanded candidates print as leaves; sub-threshold siblings collapse into one `… N others` line.

Properties that matter:
- **The budget is a hard node count**, so output length is predictable: one line per node, ~12–15 tokens/line. `max_nodes: 200` ≈ 2.5–3 k tokens. No binary search on a size threshold needed.
- **Detail follows size, not depth.** A 14 GiB directory eight levels down gets expanded before a 200 MiB one at depth 1 — which is exactly the ranking a human doing this by hand applies.
- **It is the same "expand by weight" walk the map already performs for LOD** ([TreemapWorld](../../Sources/SpaceMatters/Views/TreemapWorld.swift) expands by projected area). Same intuition, different budget unit.
- The synthetic own-files child (`directFilesPhysical` / `directFileCount`) mirrors [TreemapLayout.buildItems](../../Sources/SpaceMatters/Views/TreemapLayout.swift#L209)'s own-files block. Without it, a folder whose bytes are all in loose files reads as empty.

### 3.2 Output format — proportions first, one unit, no ASCII art

```
286G  Macintosh HD                                   100%
  190G  Users/rducom                                  66%
     62G  sources                                     33%  ~go,rs,pack
     56G  Library                                     29%
        35G  Application Support                      63%
           14G  Code                                  41%  cold:8mo
            7G  Google                                21%
            9G  … 41 others                           26%
      1G  (files here, 412)                            1%
```

Decisions:
- **Percent of parent**, always. A model reasons far better in proportions than in absolute GiB, and it is what makes "41 % of Application Support is VS Code" land as a finding.
- **Relative paths.** Indentation carries the hierarchy; only the root prints absolutely. Halves the token cost of deep trees and removes the `path(for:)` walk from the hot loop.
- **One size unit per line, 3 significant digits.** Reuse [Format.bytes](../../Sources/SpaceMatters/Util/Formatting.swift).
- **Annotations are suffixes, never columns**: `~go,rs,pack` (dominant extensions), `sparse`/`compressed` (from `divergence.label`, prose already written in [SizeDivergence.summary](../../Sources/SpaceMatters/Model/FSNode.swift#L216)), `cold:8mo` (§3.4), `cache:go-mod` (catalog membership). Absent annotation = nothing notable, costing zero tokens.
- **Text, not JSON.** JSON of the same tree costs roughly 3× the tokens for zero added meaning at this shape. The MCP tools return text content blocks.

`TreeDigest` lives in `Sources/SpaceMatters/Model/TreeDigest.swift`, is a pure function of `(root: FSNode, seedPaths: [ObjectIdentifier: String], options)`, is `Sendable`, touches no AppKit, and is therefore testable and callable from both the MainActor GUI and a headless stdio loop.

### 3.3 The tool surface

Read-only by construction. Every tool takes an optional `path` scoping it to a subtree (resolved with the same logic as [resolveNode](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L771), fenced to the scan root — a path outside it is an error, not a silent re-scan).

| Tool | Arguments | Returns |
|---|---|---|
| `overview` | — | Volume, totals, counts, scan date, elapsed, skipped count; top file types; `TreeDigest(max_nodes: 120)`; the Low-Hanging Fruits report. **One call, enough to start reasoning.** |
| `tree` | `path`, `max_nodes` (def. 200) | §3.1/§3.2 verbatim. |
| `top` | `path`, `by: size\|count`, `ext`, `limit` | Flat descending ranking of directories in the subtree. |
| `types` | `path`, `limit` | Extension breakdown. Exact for the whole scan; **an explicitly-labelled estimate for any subtree** (§4 step 4 — no exact form is derivable from the tree). |
| `find` | `pattern` (glob on directory name), `min_size` | **The tool with no cheap shell equivalent.** "340 `node_modules`, 22 GiB total, top 10 by size" is a one-pass walk over an in-memory tree and a `find \| xargs du` storm otherwise. |
| `aged` | `path`, `older_than` (e.g. `6mo`), `min_size` | Subtrees whose newest write predates the cutoff (§3.4). |
| `explain` | `path` | Everything known about one node: both sizes + divergence cause and prose, dominant extension, file/dir counts, newest mtime, catalog membership + its `note`, whether a native cleaner is required and available, recent journal entries touching it. |
| `cleanup_targets` | — | The detected catalog with per-target sizes and `note`s. Read-only: **no `clean` tool.** |
| `annotate` | `path`, `verdict: safe\|review\|keep`, `reason` | Connected mode only (§3.5). |
| `focus` | `path` | Connected mode only. |

**Why no delete tool.** A model that can both measure and delete is a model one bad inference away from removing a user's photo library. The read-only boundary is also what makes the server installable without a security conversation, and it costs nothing: the model's output is a plan, and the app already has a vetted, journalled, fenced deletion path ([CleanupEngine](../../Sources/SpaceMatters/Scanner/CleanupEngine.swift#L20) — hand-picked catalog, `allowedRoot` fence, never follows symlinks, never removes the cache root itself) that the user drives with a click.

### 3.4 The one scanner change: `ATTR_CMN_MODTIME`

Cost: one more bit in the attribute list already being requested. **No extra syscall**, no extra `getattrlistbulk` round-trip, ~16 bytes per entry in a buffer that is reused across calls.

Parse-order note, which is where this kind of change goes wrong: `ATTR_CMN_MODTIME` is `0x0000_0400`, so in the buffer's ascending-bit packing it lands **after `OBJTYPE` (0x08) and before `FLAGS` (0x0004_0000)** — i.e. a new gated read inserted between [FSAttr.swift:167](../../Sources/SpaceMatters/Scanner/FSAttr.swift#L167) and the `FLAGS` block, reading a `timespec` (16 B) and gated on the returned-attrs mask exactly like its neighbours. Get the position wrong and every subsequent offset misaligns.

**Storage — recommended: max-propagation, 8 bytes per node.** Add `newestMTime = Atomic<Int64>(0)` to `FSNode`, set from the max over a directory's direct files in `finishScan`, propagated to ancestors as a CAS-max alongside the existing size propagation. 670 k dirs × 8 B ≈ 5 MB. It answers the binary question that matters — *has anything in this subtree been written since date X* — and a `false` there is a strong, safe signal.

⚖️ Considered and deferred: a 4-bucket bytes-by-age histogram per node (`<30d / <180d / <1y / older`, 32 B/node ≈ 21 MB). Strictly more informative ("of these 14 GiB, 12 GiB untouched for over a year" beats "something in here was touched last week"), but it needs per-file bucketing in the scan hot loop and it is not needed to make `aged` useful. Follow-up, once max-propagation has proven the feature earns its keep.

### 3.5 Detached vs connected — attach if you can, scan if you can't

The MCP process and the GUI are different processes, so `annotate`/`focus` need IPC. Two modes, one binary:

- **Detached** (always works): `--mcp` scans on its first tool call and holds the tree for the life of the process. An MCP stdio server lives as long as the session, so the 33 s scan is paid **once** and every later call is instant. ~130 MB resident for a 670 k-dir tree. Optionally emit MCP progress notifications against the first call's `progressToken` so the session sees the scan advance instead of a silent minute.
- **Connected**: on startup `--mcp` tries `~/Library/Application Support/SpaceMatters/mcp.sock`, a Unix domain socket the GUI listens on once a scan has finished. If it connects, it proxies every tool to the running app: **no re-scan at all**, the session sees exactly the tree the user is looking at, and `annotate`/`focus` become trivial. If the connect fails, it falls back to detached silently.

⚖️ Rejected: a snapshot file dumped by the GUI and read by the MCP process. It adds a serialisation format, a staleness policy, and a cache-invalidation problem, and it still cannot carry the return channel. The socket gives strictly more for comparable work; detached mode already covers "app not running".

Verdicts arriving via `annotate` are held in a `[ObjectIdentifier: Verdict]` side-map on `ScanController` (not on `FSNode` — it must survive nothing and cost nothing when unused), bump `highlightVersion`, and feed the existing per-instance tint path that search and type-highlight already use in both renderers ([TreemapMetalRenderer](../../Sources/SpaceMatters/Views/TreemapMetalRenderer.swift), [SunburstMetalRenderer](../../Sources/SpaceMatters/Views/SunburstMetalRenderer.swift)). This is the cheapest possible integration of the whole spec and the one with the highest visible payoff: **the treemap, recoloured by what a model thinks you can delete.**

### 3.6 The skill — MCP is the data, the skill is the method

Shipped in `Packaging/skills/space/SKILL.md`, installed by an app menu item that also writes the `claude mcp add` config. It carries what the model cannot infer:

- **Procedure**: `overview` first, always. Drill the top 3 by share. `find` for scattered patterns (`node_modules`, `.venv`, `target`, `DerivedData`) before drilling — cumulative totals reorder the priorities. Cross-check every candidate with `aged`. Never propose a command for a path that `explain` reports as catalog-managed — point at the app's cleanup pass instead.
- **Domain knowledge**: `.pack` = git objects (never delete, `git gc` instead), `Application Support/Code/workspaceStorage` keeps state for repos deleted years ago, `CoreSimulator/Devices` grows without bound, `.raw` at 38 GiB is a photo library and belongs on an external drive, not in a delete plan.
- **Output contract**: a table of `{path, size, verdict, reason, command}` — and a call to `annotate` for each row, so the conclusions land on the map rather than only in the transcript.

### 3.7 Phase 0 — the clipboard briefing, which should ship first

A **"Copy LLM briefing" (⌘⇧C)** menu item that puts `TreeDigest` of the current view (~4 k tokens, current zoom root, current counting mode) on the clipboard.

It is twenty lines on top of §3.1, it needs no MCP install and no `--mcp` mode, it works with *any* assistant, and — the real reason it goes first — **it validates the payload format against real conversations before any transport work is committed.** If the digest turns out to need mtime, or percentages of root as well as parent, or a different annotation set, that is discovered here for a day's work instead of after the server is built on top of it.

## 4. Implementation plan

**Phase 0 — digest + briefing (~0.5 d)**
1. `Model/TreeDigest.swift`: heap expansion, own-files synthesis, `… N others` rollup, renderer, `DigestOptions { maxNodes, metric, annotations }`.
2. Menu item + `⌘⇧C` in [SpaceMattersApp.commands](../../Sources/SpaceMatters/App/SpaceMattersApp.swift#L50), reading `zoomRoot ?? root` off `ScanController`.

**Phase 1 — time (~0.5 d)**
3. `ATTR_CMN_MODTIME` in [FSAttr](../../Sources/SpaceMatters/Scanner/FSAttr.swift#L94) at the correct packing position; `BulkEntry.modTime`. `FSNode.newestMTime` + CAS-max propagation in `finishScan`. `cold:Nmo` annotation in the digest. Verify against the golden fixtures that nothing else shifted.
4. ~~Per-subtree extension rollup (walk + accumulate into a `[ExtKey: ExtStat]`)~~ — **corrected during implementation: an exact one cannot exist.** The walk has nothing to accumulate: files are not objects and no per-directory extension table survives a scan, because collapsing files into their parent *is* the memory design ([FSNode](../../Sources/SpaceMatters/Model/FSNode.swift#L6)). The only surviving per-directory type signal is `dominantExt`. Storing a real table per directory would cost more than the tree itself and is refused on the same grounds the file objects were. So: [TreeQuery.approximateTypes](../../Sources/SpaceMatters/Model/TreeQuery.swift) attributes each directory's own-file bytes wholly to its dominant extension, and **every surface that shows it must label it an estimate** — only `DirectoryScanner.snapshotExtensions` is exact, and it cannot be scoped.

**Phase 2 — MCP, detached (~1.5–2 d)**
5. `App/MCP/JSONRPC.swift`: line-framed JSON-RPC 2.0 over stdin/stdout. ~150 lines, no dependency — do not add an SDK for three methods.
6. `App/MCP/MCPServer.swift`: `initialize` / `tools/list` / `tools/call`, tool schemas, lazy scan on first call, optional progress notifications.
7. `App/MCP/Tools.swift`: the §3.3 read-only tools over `TreeDigest` + a `TreeQuery` helper (resolve, walk, glob, rank), all path-fenced to the scan root.
8. `--mcp [path]` branch in `Entry.main`, before the GUI fallthrough.

**Phase 3 — connected + verdicts (~2 d)**
9. GUI-side `MCPSocketServer` on `~/Library/Application Support/SpaceMatters/mcp.sock`, started when a scan finishes, stopped on rescan; `--mcp` tries it first and proxies.
10. `annotate` → verdict side-map on `ScanController` + `highlightVersion` bump; verdict tint folded into both renderers' instance colour; a legend chip and a "clear verdicts" action.
11. `focus` → existing `reveal(_:)` / `zoom(into:)`.

**Phase 4 — skill + install (~0.5 d)**
12. `Packaging/skills/space/SKILL.md` + references. Menu item "Set up Claude integration…" writing the MCP config and copying the skill to `~/.claude/skills/`, showing exactly what it will write before it writes it.

## 5. Verification

- **Unit** (`Tests/SpaceMattersTests/TreeDigestTests.swift`): budget is respected exactly (`nodes emitted ≤ maxNodes`); expansion order is size-descending; percentages of each expanded node's children + own-files + `… N others` sum to 100 ± rounding; a deep-and-thin tree and a wide-and-flat tree both stay within budget; relative paths recompose to the absolute ones; empty tree and single-node tree don't crash.
- **Unit** (`MCPProtocolTests.swift`): `initialize` handshake, `tools/list` schema validity, unknown method → proper JSON-RPC error, path outside the scan root → error not silent re-scan, malformed line doesn't kill the loop.
- **Golden** ([ScannerGoldenTests](../../Tests/SpaceMattersTests/ScannerGoldenTests.swift)): after the `MODTIME` change, sizes and counts on the fixture tree are **byte-identical** to before — the parse-offset regression this spec is most exposed to. Plus a fixture with a known-old file asserting `newestMTime`.
- **Live**: `--mcp` driven by an actual Claude Code session against this machine's home directory, end to end — `overview`, drill, `find node_modules`, `aged 1y`, `explain`. Success criterion is not "the tools returned data" but **"the session produced a delete plan a human agrees with, in under ~15 k tokens of tool output"**. Then the same run in connected mode with the GUI open, checking that the treemap recolours and no re-scan occurs.
- **Negative**: MCP process launched with no Full Disk Access → clean, explanatory error, not a silent 90 %-short total (see 🔬 below).

## 6. Risks & assumptions 🔬

- ~~**TCC / Full Disk Access in detached mode is the big unknown.**~~ **Measured in phase 2 — see §0c.** FDA turns out not to be granted to the app at all on the development machine, so the transfer question stays open, but detached mode is no blinder than the GUI the user already runs. Mitigation shipped: `FullDiskAccess.isGranted` gates a caveat carried on every tool response (full text on `overview`, one line elsewhere). **Still to settle**: whether a granted bundle's FDA follows a binary spawned by Claude Code. If it does not, connected mode (phase 3) becomes the only way to reach protected locations, which raises its priority above the verdict work.
- **Scan cost per session.** 33 s on the first tool call is acceptable once; it is not acceptable if the model opens a second server or the session restarts. Connected mode is the real answer; detached should at minimum print its scan scope so a session doesn't re-request it.
- **Prompt injection through the filesystem.** Directory names are attacker-controllable in the general case (a downloaded archive can contain a folder named to look like an instruction). Digest output must be clearly framed as data, names truncated to a sane length, and control characters stripped. Low severity given the read-only surface — but the surface is read-only *partly for this reason*, and that ordering should not be reversed later.
- ~~**Verdict staleness.**~~ **Resolved in phase 3**: paths are the source of truth and the node map is re-resolved from them on every `bump()`, so a verdict follows a rebuilt subtree. Locked by `verdictsSurviveTheTreeBeingRebuilt`, which asserts the fixture actually produced fresh objects before checking the verdict survived — a test that would otherwise pass for the wrong reason.
- **`find`'s glob is over directory names only.** Files are not objects ([FSNode.swift:6](../../Sources/SpaceMatters/Model/FSNode.swift#L6)), so `find "*.raw"` cannot be answered from the tree — only from the extension rollup, at aggregate granularity. The tool schema must say so, or a model will conclude the disk has no `.raw` files.
- **`max_nodes` is advisory to the model.** Nothing stops a session from calling `tree` with a huge budget twenty times. The server should cap `max_nodes` (≈ 1000) and note the cap in the response.

## 7. Effort & dependencies

| Phase | Effort | Depends on |
|---|---|---|
| 0 — `TreeDigest` + clipboard briefing ✅ | 0.5 d | — |
| 1 — `ATTR_CMN_MODTIME` + subtree type estimate ✅ | 0.5 d | — |
| 2 — MCP server, detached, read-only ✅ | 1.5–2 d | 0, 1 |
| 3 — Connected mode, `annotate`, `focus` ✅ | 2 d | 2, SPEC-09/10/13 (shipped) |
| 4 — Skill + one-click setup | 0.5 d | 2 |

**Total ~5–6 d**, shippable in four independently useful increments. Phase 0 alone delivers most of the user-visible value; Phase 3 is what makes it a feature no other disk analyser has.
