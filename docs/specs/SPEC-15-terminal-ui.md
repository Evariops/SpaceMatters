# SPEC-15 — Terminal UI: the app, in a terminal

> **Request**: a TUI version of SpaceMatters — and then: make it play the game of a real TUI, without losing features, with a proper menu and a way to delete.
> **Status**: 🟢 **Phase 1 implemented** — `SpaceMatters --tui [path]`: [TUI](../../Sources/SpaceMatters/TUI/TUI.swift), [TUIApp](../../Sources/SpaceMatters/TUI/TUIApp.swift), [AppTUIHost](../../Sources/SpaceMatters/TUI/AppTUIHost.swift), the screens ([home](../../Sources/SpaceMatters/TUI/TUIHome.swift), [browser](../../Sources/SpaceMatters/TUI/TUIBrowser.swift), [results & tables](../../Sources/SpaceMatters/TUI/TUIResults.swift), [cleanup](../../Sources/SpaceMatters/TUI/TUICleanupScreen.swift)), [Terminal](../../Sources/SpaceMatters/TUI/Terminal.swift), [TextCell](../../Sources/SpaceMatters/TUI/TUIText.swift), 41 tests in [TUITests](../../Tests/SpaceMattersTests/TUITests.swift).
> **Guiding constraint**: same engine, same tree, same controllers. The terminal is a different *view* of the app, never a second app — and never a weaker promise.

## 1. Objective

Use SpaceMatters without a window: over `ssh` into a Mac, from a terminal-first workflow, or because opening an app to answer "where did 40 GiB go?" is more ceremony than the question deserves.

Phase 0 was the directory outline, read-only. Phase 1 is the app: the home menu with everything worth analysing, the outline with files in it, the queries behind the MCP tools, the Low-Hanging Fruits pass, and deletion — each with the confirmation a keystroke owes a filesystem.

What is still deliberately out:

- **No treemap or sunburst.** A block-character treemap is a fun demo and an unreadable tool at 80×24. The per-row bar carries the proportion, and `T` (largest) / `A` (cold) answer what the map is usually scanned for.
- **No container or Kubernetes *actions*.** Those views are read-only here: pruning images is `podman`'s own semantics, and the app's container mode is where that is done with its own confirmations.
- **No dependency.** No curses, no TUI framework: plain VT/ANSI sequences on raw `termios`, as the MCP server's JSON-RPC is hand-rolled rather than imported.
- **No network.** It is the app and a terminal; the README's "the only network request is the update feed" stays true.

## 2. Design

### 2.1 One host, two front-ends

The terminal does not reimplement scanning, deleting or cleaning. It drives `ScanController` and `CleanupController` — the same objects the window binds to — through one protocol:

| File | Role | Touches a descriptor, a disk or the main actor |
|---|---|---|
| [TUIHost](../../Sources/SpaceMatters/TUI/TUIHost.swift) | the vocabulary: status, sources, targets, requests | no (types only) |
| [AppTUIHost](../../Sources/SpaceMatters/TUI/AppTUIHost.swift) | the real host: hops to the main actor, runs long work as jobs | yes |
| [TUIApp](../../Sources/SpaceMatters/TUI/TUIApp.swift) | routing, chrome, overlays (confirm, menu, prompt, help) | no |
| [TUIHome](../../Sources/SpaceMatters/TUI/TUIHome.swift), [TUIBrowser](../../Sources/SpaceMatters/TUI/TUIBrowser.swift), [TUIResults](../../Sources/SpaceMatters/TUI/TUIResults.swift), [TUICleanupScreen](../../Sources/SpaceMatters/TUI/TUICleanupScreen.swift) | screens: keys in, lines out | no |
| [Terminal](../../Sources/SpaceMatters/TUI/Terminal.swift) | raw mode, alternate screen, size, bytes → `TerminalKey` | yes (the decoder is pure) |

A screen never acts. It returns a `TUIRequest` — `.confirmDelete(target, permanently:)`, `.find(node)`, `.toggle(id)` — and `TUIApp` decides whether that needs a confirmation, a route change or a call into the host. Which is why the whole interface, deletion included, is tested as values against a fake host: 41 tests, no disk, no `kubectl`, no Trash.

The alternative — a second implementation of tree surgery for the terminal — is exactly how two views drift apart on the one operation that cannot be taken back.

### 2.2 Threads: the run loop keeps the main thread

`ScanController` and `CleanupController` are `@MainActor`, and the live refresh rides the main run loop (`Timer`, FSEvents). So:

- the **main thread** runs `RunLoop.main.run()` — the main actor, the refresh timer, FSEvents;
- the **frame loop** gets a thread of its own, and reaches the controllers through `AppTUIHost`, which hops with `DispatchQueue.main.sync`.

Blocking on `poll()` in the thread that owes the run loop its time is how a "live" view stops filling in.

Long operations — a delete, a clean, a `kubectl` round-trip, the probes — run as a **job**: started on the main actor, named in the header with a spinner, collected when it lands. One at a time (tree surgery must not overlap), the list keeps drawing underneath, and the terminal keeps answering keys. Quitting while a job runs asks first, because quitting is what would stop it halfway.

### 2.3 Deleting, and what stands in front of it

Phase 0 refused deletion on the grounds that "a keystroke in a terminal is not a fenced, journalled cleanup pass". The answer in phase 1 is not to loosen that bar but to clear it: the terminal calls `ScanController.remove(directory:permanently:)` and `CleanupController.cleanSelected()`, so it inherits every guard the window has — host scans only, never mid-scan, one structural operation at a time, epoch-checked across every suspension, aggregates and the file-type table corrected on the way back, `cleanup.jsonl` journalled.

On top of that, the terminal adds its own:

| Fence | Why |
|---|---|
| `d` moves to the **Trash**; `D` deletes for good | the reversible path is the default and the easy keystroke |
| the Trash takes `⏎`, permanent deletion only takes `y` | ⏎ is muscle memory; it must not be enough where nothing comes back |
| the confirmation shows size **and** the resolved full path | the wrong `node_modules` is one row away |
| refused mid-scan, on VM/SSH scans, on the scan root, while a job runs | each stated in the footer rather than silently ignored |
| `space` picks, nothing is pre-picked; "select all" skips non-regenerable targets | the Trash and orphaned editor state are ticked one by one or not at all |
| the frame says what happened: "Moved to Trash — node_modules (1.2 GiB)" | and the screens reconcile, so a trail standing inside a deleted folder walks back out |

### 2.4 The screens

**Home** — mounted volumes with their usage bar, the home folder, any path you type, Low-Hanging Fruits, Podman/Colima machines (whole VM or just container storage), the container engine, every `kubectl` context. The same list the window's splash offers, gathered by a job because every probe shells out.

**Browser** — the outline, plus what phase 0 did not have: files listed one by one (`ScanController.filesIn`, capped per folder, the remainder kept as one aggregate row so the bytes are never lost), four rankings (`s`: size, name, files, written), the file-type panel (`t`), re-read one folder (`r`) through SPEC-02 invalidation, rescan everything (`R`), copy the briefing (`c`), reveal/open in Finder (`o`/`e`).

**Results** (`/`, `T`, `A`) — `TreeQuery.find`, `.top` and `.aged`: the MCP tools' questions, answered without an assistant. A bare word becomes `*word*`; nested matches are not double-counted. `⏎` walks the browser to a hit, `d` deletes it through the same confirmation.

**Low-Hanging Fruits** — the catalog sized one target at a time, blocked rows explained in place ("Slack is running — quit it first", "needs the Go toolchain"), native cleaners named, and the freed bytes measured rather than assumed.

**Kubernetes / containers** — one read-only table shape: PVCs by capacity against live usage, images, volumes and containers by size. Columns drop by priority as the terminal narrows, as the browser's do.

### 2.5 What a row says

```
   on disk       %                files   written  name
  12.4 GiB   48.2%  ████▊         1,204    3mo ago  Library/
   6.1 GiB   23.7%  ██▍          88,311     2d ago  Developer/ …
 812.0 MiB    3.1%  ▎                 1    1y ago  big-disk-image.raw  (sparse)
```

- On-disk size only, as everywhere in the app. Where the apparent size notably diverges, the row and the location line name it (`sparse`, `compressed`) through the same `SizeDivergence` rule.
- `written` is the max-propagated watermark of SPEC-14 phase 1; `—` when unknown, never 1970.
- A folder no worker has read yet carries a trailing `…`: a placeholder that will fill in, not a small folder.
- Columns drop by priority as the terminal narrows: files below 76 cells, written below 64, the bar below 50. Size, share and name always stay.

Two consequences of rows that re-sort ten times a second: **the selection follows a node, not an index**, and **sizes are sampled once per sort** (a comparator that reads a moving atomic twice can disagree with itself).

### 2.6 File names are untrusted bytes

A folder named `\e]0;…\a\e[2J` would *drive* the terminal it is printed on. Control and format characters are dropped before display — in rows, in modal titles, in the action menu's labels, everywhere a name is quoted back. And a `Character` count is not a width: CJK and emoji take two cells, combining marks none. `TextCell` measures in cells, autowrap is off while the browser runs, and a modal that cannot fit a frame (under ~24 cells) drops the frame rather than drawing a border wider than the terminal.

### 2.7 The terminal is always given back

Raw mode turns off signal generation, so Ctrl-C and Ctrl-D arrive as keys and quit through the normal path. `SIGTERM` and `SIGHUP` restore the terminal from a handler that only calls `write` and `tcsetattr`, both async-signal-safe. If input disappears (the terminal is closed), the loop stops instead of spinning on a descriptor that reads as ready forever.

## 3. Keys

| Key | Action |
|---|---|
| `↑` `↓` / `k` `j`, `PgUp` `PgDn`, `g` `G` | move, page, jump |
| `→` `⏎` / `l` | open a folder (or describe a file) |
| `←` `⌫` / `h` | up one level (`esc` too); at the root, back to the home menu |
| `t` · `s` · `i` | file types · change sort · what is this |
| `/` · `T` · `A` | find by name · largest folders · cold folders (6 months+) |
| `d` / `fn⌫` · `D` | move to the Trash · delete permanently (asks with `y`) |
| `r` · `R` | re-read this folder · rescan everything |
| `c` · `o` · `e` | copy a briefing · reveal in Finder · open |
| `space` · `a` · `⏎` (cleanup) | pick a target · pick every regenerable one · empty them |
| `m` · `?` · `q` · Ctrl-C | action menu · keys · back · quit |

The action menu (`m`) is also the legend: every entry shows the key that runs it from the screen below, and typing that key runs it from inside the menu.

## 4. Verification

- `swift test --filter TUITests` — 41 tests: the key grammar (both cursor modes, modifiers, a sequence cut by the read, typed UTF-8), row ranking and the selection following a folder that overtakes its siblings, the four sorts, frames within `width × height` for every size from 1×1 to 140×30 **with every overlay open**, hostile names in rows *and* modals, and the destructive paths — Trash asks then deletes, permanent refuses `⏎`, escape cancels, refusals mid-scan / on a VM scan / on the scan root, cleanup needs a pick then a `y`, quitting mid-job asks first.
- Live: `swift build && .build/debug/SpaceMatters --tui ~`. Check the list fills while the header says `scanning…`; resize mid-scan; open a folder still marked `…`; `t`, `/`, `T`, `m`, `?`; quit with `q`, then Ctrl-C, then `kill` the process from another shell — the prompt must come back cooked every time.
- Destructive, on a throwaway folder: `d` then `⏎` must move exactly the selected folder to the Trash and say so; `D` then `⏎` must do nothing.
- Cross-check: the header's totals at the end of a scan against `--scan` on the same path.

## 5. Risks & assumptions (🔬)

- 🔬 **Cell widths** cover the East Asian Wide blocks and emoji presentation, not all of UAX #11. Ambiguous-width characters are counted as one cell; a terminal configured to draw them wide clips the line end rather than wrapping (autowrap off).
- 🔬 The block characters of the bar (`▏…█`) are assumed one cell wide, which holds for the terminals macOS users run with default settings.
- 🔬 `DispatchQueue.main.sync` from the frame thread assumes the main run loop is alive. It is started before the frame thread and never stopped; the process exits from the frame loop, after restoring the terminal.
- 🔬 Full Disk Access is a property of the *binary*. The app bundle has it; `.build/debug/SpaceMatters` is a different binary, so a dev build sizes protected locations (the Trash) as `denied` — shown as such, never as 0 B.

## 6. Next, in order of value per line of code

1. **Multi-select** in the browser (`x` to mark, one confirmation for the batch) — the window has it (⌘⌫); the terminal deletes one row at a time.
2. **Verdict marks** from an MCP session shown in the rows, so a terminal and an assistant can look at the same tree.
3. **`--tui --vm podman` / `--tui --k8s <ctx>`** — argument parsing over routes that already exist.
4. **OSC 52** as a clipboard fallback for `c` over `ssh`, where `NSPasteboard` is the wrong machine's.
