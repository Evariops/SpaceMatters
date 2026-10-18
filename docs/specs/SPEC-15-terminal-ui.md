# SPEC-15 — Terminal UI: the outline, live, in a terminal

> **Request**: a TUI version of SpaceMatters, even a minimal one.
> **Status**: 🟡 **Phase 0 implemented** — `SpaceMatters --tui [path]`: [TUI](../../Sources/SpaceMatters/TUI/TUI.swift), [TUIBrowser](../../Sources/SpaceMatters/TUI/TUIBrowser.swift), [Terminal](../../Sources/SpaceMatters/TUI/Terminal.swift), 15 tests in [TUITests](../../Tests/SpaceMattersTests/TUITests.swift). Live driving on a real disk is still to do (§5).
> **Guiding constraint**: same engine, same tree, same live fill. The terminal is a different *view* of the scan, never a different scanner and never a weaker promise.

## 1. Objective

Browse a scan without a window: over `ssh` into a Mac, from a terminal-first workflow, or because opening an app to answer "where did 40 GiB go?" is more ceremony than the question deserves.

The headless subcommands already answer that question once (`--scan` prints totals, `--briefing` prints a digest). What they can't do is let you *walk* the answer. Phase 0 is the directory outline as an interactive list that fills in while the scan runs: what the window's outline does, minus the maps.

Non-goals, each deliberate:

- **No deletion, no cleanup.** The app's cleanup pass is fenced and journalled; a keystroke in a terminal is neither. Same line as the MCP server: the TUI can show you what to delete, and the app is what deletes it.
- **No treemap or sunburst.** A block-character treemap is a fun demo and an unreadable tool at 80×24. The per-row bar carries the proportion.
- **No dependency.** No curses, no TUI framework: plain VT/ANSI sequences on raw `termios`, as the MCP server's JSON-RPC is hand-rolled rather than imported.
- **No network.** It is the scanner and a terminal; the README's "the only network request is the update feed" stays true.

## 2. Current state of the code it builds on (verified)

- **Entry routing** — [Entry.main](../../Sources/SpaceMatters/App/SpaceMattersApp.swift#L8) dispatches every headless subcommand before `SpaceMattersApp.main()`. `--tui` is one more branch, with `--mcp`'s default root (`$HOME`: the bytes a user can act on).
- **The scan pattern** — [HeadlessScan.run](../../Sources/SpaceMatters/App/HeadlessScan.swift#L12): an `FSNode` root, one `DirectoryScanner.Seed`, `recommendedSkipPaths`, `start()`. The TUI uses it verbatim, except that instead of spinning until `isFinished` it draws while it waits.
- **Live reads are already safe off the main actor** — `FSNode`'s sizes are atomics and its children are guarded by `gTreeLock`, exactly so a reader outside the UI can sample a tree that workers are still filling (the MCP socket thread relies on the same property).
- **Formatting** — `Format.bytes` (IEC, localized separator), `Format.count`, `Format.age` are shared, so a size reads identically in the window, the briefing and the terminal.

## 3. Design

### 3.1 Three files, one of them pure

| File | Role | Touches a file descriptor |
|---|---|---|
| [TUIBrowser](../../Sources/SpaceMatters/TUI/TUIBrowser.swift) | navigation state, rows, frame rendering, cell-width maths | no |
| [Terminal](../../Sources/SpaceMatters/TUI/Terminal.swift) | raw mode, alternate screen, window size, input → `TerminalKey` | yes (the decoder itself is pure) |
| [TUI](../../Sources/SpaceMatters/TUI/TUI.swift) | starts the scanner, runs the 10 Hz loop | yes |

`TUIBrowser.render(width:height:status:)` returns the frame as `[String]`, so every screen is a value a test can compare — the `TreeDigest` approach applied to an interactive view.

### 3.2 Live, at the GUI's cadence

The loop samples the atomics every 100 ms, the rate the window reads them. Each frame is diffed line by line against the previous one and only changed lines are written, so a finished scan sitting idle costs a `poll()` and nothing else.

Two consequences of rows that re-sort ten times a second:

- **The selection follows a node, not an index.** A highlight pinned to "row 3" would slide onto a different folder under the cursor as sizes grow.
- **Sizes are sampled once per sort.** A comparator that reads a moving atomic twice can disagree with itself.

A folder no worker has read yet carries a trailing `…`: it is a placeholder that will fill in, not a small folder.

### 3.3 What a row says

```
   on disk       %                files   written  name
  12.4 GiB   48.2%  ████▊         1,204    3mo ago  Library/
   6.1 GiB   23.7%  ██▍          88,311     2d ago  Developer/ …
 812.0 MiB    3.1%  ▎               143    1y ago  [143 files here]
```

- On-disk size only, as everywhere in the app. Where the apparent size notably diverges, the location line names it (`sparse`, `compressed`) through the same `SizeDivergence` rule.
- **Own files are one row**, ranked among the sub-folders by size — the tree keeps them as one aggregate (files are never nodes), and the digest orders them the same way.
- `written` is the max-propagated watermark of SPEC-14 phase 1; `—` when unknown, never 1970.
- Columns drop by priority as the terminal narrows: files below 76 cells, written below 64, the bar below 50. Size, share and name always stay.

### 3.4 File names are untrusted bytes

A folder named `\e]0;…\a\e[2J` would *drive* the terminal it is printed on. Control and format characters are dropped before display, as the digest does. And a `Character` count is not a width: CJK and emoji take two cells, combining marks none, and a line misjudged one cell too wide wraps and shears every line below it. `TextCell` measures in cells, and autowrap is switched off while the browser runs as a second fence.

### 3.5 The terminal is always given back

Raw mode turns off signal generation, so Ctrl-C and Ctrl-D arrive as keys and quit like `q` through the normal path. `SIGTERM` and `SIGHUP` restore the terminal from a handler that only calls `write` and `tcsetattr`, both async-signal-safe. If input disappears (the terminal is closed), the loop stops instead of spinning on a descriptor that reads as ready forever.

### 3.6 Keys

| Key | Action |
|---|---|
| `↑` `↓` / `k` `j` | move |
| `PgUp` `PgDn`, `Home` `End` / `g` `G` | page, jump |
| `→` `⏎` / `l` | open folder |
| `←` `⌫` / `h` | up one level, landing on the folder just left |
| `t` | file types: scan-wide and exact (`snapshotExtensions`) |
| `q`, Ctrl-C | quit |

## 4. Implementation (phase 0, done)

1. `Sources/SpaceMatters/TUI/` — the three files above.
2. `--tui [path]` in `Entry.main`. Refuses with exit 2 when stdin or stdout isn't a terminal, and points at `--scan` / `--briefing` instead.
3. Tests — key grammar (both cursor modes, modifiers, a sequence cut by the read), row ranking, the selection following a folder that overtakes its siblings, open/back symmetry, frames within `width × height` for every size from 1×1 to 140×30 with wide, combining and emoji names, hostile names, the live `…` marker.

## 5. Verification

- `swift test --filter TUITests`.
- Live: `swift build && .build/debug/SpaceMatters --tui ~` in Terminal.app and one third-party terminal. Check the list fills while the header says `scanning…`; resize mid-scan; open a folder still marked `…` and watch it fill; `t` and back; quit with `q`, then with Ctrl-C, then `kill` the process from another shell — the prompt must come back cooked every time.
- Cross-check: the header's totals at the end of a scan against `--scan` on the same path.

## 6. Risks & assumptions (🔬)

- 🔬 **Cell widths** cover the East Asian Wide blocks and emoji presentation, not all of UAX #11. Ambiguous-width characters are counted as one cell; a terminal configured to draw them wide clips the line end rather than wrapping (autowrap off).
- 🔬 The block characters of the bar (`▏…█`) are assumed one cell wide, which holds for the terminals macOS users run with default settings.

## 7. Next phases & effort

Phase 0: ~1 d. Candidates, in order of value per line of code:

1. **Search** (`/`) on the current subtree — `TreeQuery.find`, so "every `node_modules` and their total" works in the terminal as it does over MCP.
2. **Copy briefing** (`c`) — print `TreeDigest.briefing` for the current folder on exit, or through OSC 52 to the clipboard.
3. **Other sources** — the VM and Kubernetes backends already build the same `FSNode` tree; `--tui --vm podman` is mostly argument parsing.
4. **Rescan** (`r`) on the current folder, through SPEC-02's invalidation.
