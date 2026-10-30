# SPEC-15 — Terminal UI: the app, in a terminal

> **Request**: a TUI version of SpaceMatters — and then: make it play the game of a real TUI, without losing features, with a proper menu and a way to delete.
> **Status**: 🟢 **Phase 1 implemented** — `SpaceMatters --tui [path]`: [TUI](../../Sources/SpaceMatters/TUI/TUI.swift), [TUIApp](../../Sources/SpaceMatters/TUI/TUIApp.swift), [AppTUIHost](../../Sources/SpaceMatters/TUI/AppTUIHost.swift), the screens ([home](../../Sources/SpaceMatters/TUI/TUIHome.swift), [browser](../../Sources/SpaceMatters/TUI/TUIBrowser.swift), [results & tables](../../Sources/SpaceMatters/TUI/TUIResults.swift), [cleanup](../../Sources/SpaceMatters/TUI/TUICleanupScreen.swift)), [Terminal](../../Sources/SpaceMatters/TUI/Terminal.swift), [TextCell & Glyphs](../../Sources/SpaceMatters/TUI/TUIText.swift), 62 tests in [TUITests](../../Tests/SpaceMattersTests/TUITests.swift).
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

A screen never acts. It returns a `TUIRequest` — `.confirmDelete(target, permanently:)`, `.find(node)`, `.toggle(id)` — and `TUIApp` decides whether that needs a confirmation, a route change or a call into the host. Which is why the whole interface, deletion included, is tested as values against a fake host: 51 tests, no disk, no `kubectl`, no Trash.

The alternative — a second implementation of tree surgery for the terminal — is exactly how two views drift apart on the one operation that cannot be taken back.

### 2.2 Drawing only when something moves

Each frame is diffed line by line against the last one, and only the changed lines are written. Two details that are not decoration:

- A line that **fills** the terminal gets no `ESC[K`. With autowrap off the cursor stays *on* the last column after writing it, so erase-to-end would wipe the cell just drawn.
- The **cursor is parked** at the start of the selected row every frame. It is hidden, but Zoom and screen readers follow it, and a cursor left wherever the last write ended follows nothing.

The loop waits 100 ms for a key while the scan runs or a job is in flight, and **one second** once nothing is moving — a finished scan sitting idle costs a `poll`, not ten frames a second. Writes are retried on `EAGAIN` through `poll(POLLOUT)`; a write that is still lost makes the caller drop its record of the frame, so the next pass repaints everything rather than trusting lines that never arrived.

### 2.3 Threads: the run loop keeps the main thread

`ScanController` and `CleanupController` are `@MainActor`, and the live refresh rides the main run loop (`Timer`, FSEvents). So:

- the **main thread** runs `RunLoop.main.run()` — the main actor, the refresh timer, FSEvents;
- the **frame loop** gets a thread of its own, and reaches the controllers through `AppTUIHost`, which hops with `DispatchQueue.main.sync`.

Blocking on `poll()` in the thread that owes the run loop its time is how a "live" view stops filling in.

Long operations — a delete, a clean, a `kubectl` round-trip, the probes — run as a **job**: started on the main actor, named in the header with a spinner, collected when it lands. One at a time (tree surgery must not overlap), the list keeps drawing underneath, and the terminal keeps answering keys. Quitting while a job runs asks first, because quitting is what would stop it halfway.

### 2.4 Deleting, and what stands in front of it

Phase 0 refused deletion on the grounds that "a keystroke in a terminal is not a fenced, journalled cleanup pass". The answer in phase 1 is not to loosen that bar but to clear it: the terminal calls `ScanController.remove(directory:permanently:)` and `CleanupController.cleanSelected()`, so it inherits every guard the window has — host scans only, never mid-scan, one structural operation at a time, epoch-checked across every suspension, aggregates and the file-type table corrected on the way back. The cleanup pass journals itself; `d` and `D` are journalled by the terminal (`terminal-trash` / `terminal-delete` in `cleanup.jsonl`), since `ScanController.remove` writes no trail of its own.

On top of that, the terminal adds its own:

| Fence | Why |
|---|---|
| `d` moves to the **Trash**; `D` deletes for good | the reversible path is the default and the easy keystroke |
| the Trash takes `⏎`, permanent deletion only takes `y` | ⏎ is muscle memory; it must not be enough where nothing comes back |
| the confirmation shows size **and** the resolved full path, wrapped rather than cut | the wrong `node_modules` is one row away |
| a confirmation is only answered by a key read **after it was drawn**: the rest of the read that opened it is dropped and the input queue flushed once it is on screen; while it is up, a read bringing more than one key is refused whole | a pasted `Do you have a minute?⏎` is `D` then `y` |
| bracketed paste: a paste is text, taken by a text field and dropped everywhere else | a paste's letters are commands in the browser |
| a folder never read (unreadable, or not reached) says "size unknown", never "0 B", and `D` refuses it; after a stopped scan sizes read "at least" | "0 B on disk" reads as "it is empty" |
| refused mid-scan, on VM/SSH scans, on the scan root, while a job runs | each stated in the footer rather than silently ignored |
| `space` picks, nothing is pre-picked; "select all" skips non-regenerable targets | the Trash and orphaned editor state are ticked one by one or not at all |
| the frame says what happened: "Moved to Trash — node_modules (1.2 GiB)" | and the screens reconcile, so a trail standing inside a deleted folder walks back out |

### 2.5 The screens

**Home** — mounted volumes with their usage bar, the home folder, any path you type, Low-Hanging Fruits, Podman/Colima machines (whole VM or just container storage), the container engine, every `kubectl` context. The same list the window's splash offers, gathered by a job because every probe shells out.

**Browser** — the outline, plus what phase 0 did not have: files listed one by one (`ScanController.filesIn`, capped per folder, the remainder kept as one aggregate row so the bytes are never lost), four rankings (`s`: size, name, files, written), the file-type panel (`t`), re-read one folder (`r`) through SPEC-02 invalidation, rescan everything (`R`), copy the briefing (`c`), reveal/open in Finder (`o`/`e`).

**Results** (`/`, `T`, `A`) — `TreeQuery.find`, `.top` and `.aged`: the MCP tools' questions, answered without an assistant. A bare word becomes `*word*`; nested matches are not double-counted. `⏎` walks the browser to a hit, `d` deletes it through the same confirmation.

**Low-Hanging Fruits** — the catalog sized one target at a time, blocked rows explained in place ("Slack is running — quit it first", "needs the Go toolchain"), native cleaners named, and the freed bytes measured rather than assumed.

**Kubernetes / containers** — one read-only table shape: PVCs by capacity against live usage, images, volumes and containers by size. Columns drop by priority as the terminal narrows, as the browser's do.

### 2.6 What a row says

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

### 2.7 File names are untrusted bytes

A folder named `\e]0;…\a\e[2J` would *drive* the terminal it is printed on. Control and format characters are dropped before display — in rows, in modal titles, in the action menu's labels, everywhere a name is quoted back. And a `Character` count is not a width: CJK and emoji take two cells, combining marks none. `TextCell` measures in cells, autowrap is off while the browser runs, and a modal that cannot fit a frame (under ~24 cells) drops the frame rather than drawing a border wider than the terminal.

The *chrome* has the opposite problem. The bar's blocks, `…`, `·`, `—`, the arrows and the box drawing are East Asian **Ambiguous**: a terminal told to draw ambiguous characters wide (the common CJK setup) gives each of them two cells, and every line overflows. `SPACEMATTERS_TUI_ASCII=1` swaps them for ASCII — one cell for one cell, so a frame measured before the swap still fits after it. File names are never swapped: they are the user's data, and their width (Wide, not Ambiguous) is measured correctly.

### 2.8 The terminal is always given back

Raw mode turns off signal generation, so Ctrl-C and Ctrl-D arrive as keys and quit through the normal path. Everything else that can end the process restores the terminal first:

- **Handlers are installed before raw mode.** The window between the two is otherwise one where a crash leaves the shell raw with nobody left to fix it.
- **Every fatal signal**, not just `SIGTERM`/`SIGHUP`: `SIGINT`, `SIGQUIT`, `SIGPIPE` and the crash signals (`SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGFPE`, `SIGABRT`, `SIGSYS`, `SIGTRAP`). The handler restores, then **re-raises with the default disposition**, so the process dies of what actually killed it — `_exit(128 + signal)` would report a normal exit with a funny status and suppress the core dump.
- **The handler touches raw storage only.** The saved `termios` and the session flag live behind `UnsafeMutablePointer`s: reading a Swift `var` from a signal handler risks a dynamic exclusivity trap if the main thread is inside its accessor. The flag is cleared *after* the restore, so a second signal mid-restore repeats it instead of skipping it. The handled signals are blocked (`pthread_sigmask`) around `enter`/`leave`, where the state is half-written.
- **Job control.** `SIGTSTP` gives the terminal back cooked and then suspends for real; `SIGCONT` re-enters raw mode and repaints from scratch, because the shell has been drawing over the screen meanwhile.
- **`SIGWINCH`** is installed *without* `SA_RESTART`, so the frame loop's `poll` returns and the next frame is drawn at the new size.
- If input disappears, the loop stops with a **non-zero** status instead of reporting a clean quit (in practice the pty closing sends `SIGHUP` first, and the process dies of that).

`TERM` is checked too: `dumb` or unset is refused with exit 2, like a non-tty, rather than spraying escape sequences at something that will print them.

## 3. Keys

| Key | Action |
|---|---|
| `↑` `↓` / `k` `j`, `PgUp` `PgDn`, `g` `G` | move, page, jump |
| `→` `⏎` / `l` | open a folder (or describe a file) |
| `←` `⌫` / `h` | up one level (`esc` too); at the root, back to the home menu — after asking, since it discards the scan |
| `t` · `s` · `i` | file types · change sort · what is this |
| `/` · `T` · `A` | find by name · largest folders · cold folders (6 months+) |
| `d` / `fn⌫` · `D` | move to the Trash · delete permanently (asks with `y`) |
| `r` · `R` | re-read this folder · rescan everything |
| `c` · `o` · `e` | copy a briefing · reveal in Finder · open |
| `space` · `a` · `⏎` (cleanup) | pick a target · pick every regenerable one · empty them |
| `m` · `?` · `q` · Ctrl-C | action menu · keys · back · quit |
| Ctrl-Z, then `fg` | suspends with the terminal cooked, resumes repainted |

The action menu (`m`) is also the legend: every entry shows the key that runs it from the screen below, and typing that key runs it from inside the menu.

The **footer** deliberately shows less than this table: one way to do each thing a newcomer needs, and nothing else. The vi aliases, `g`/`G` and the page keys are the shortcuts of someone who already knows the browser, and listing them costs the last column of every row at 80 cells — where the footer is the one line that has to stay readable. `?` and `m` carry the full map, and the footer advertises both.

## 4. Verification

### 4.1 Tests

`swift test --filter TUITests` — 51 tests (283 in the suite). The key grammar (both cursor modes, modifiers, a sequence **cut by the read and carried to the next one**, `ESC q` as Meta rather than Esc, typed UTF-8); row ranking, the four sorts, and a selection that stays on its folder while the scan re-ranks the rows under it; the destructive paths (Trash asks then deletes, permanent refuses `⏎`, escape cancels, refusals mid-scan / on a VM scan / on the scan root, cleanup needs a pick then a `y`, quitting mid-job asks first); unreadable folders not reported as empty.

Two test shapes the review asked for:

- **Golden frames.** Lines compared against strings written out by hand, with the cell arithmetic in the comment. Measuring the renderer with `TextCell.width` — the function that sized it — proves internal consistency, not what a terminal draws.
- **Every threshold.** Widths 1 · 12 · 23 · 24 · 30 · 49 · **50** · 51 · 63 · **64** · 65 · 75 · **76** · 77 · 80 · 140, each with every overlay open (help, menu, both confirmations, the prompt, info) — 50, 64 and 76 are where the bar, the written column and the files column appear.

### 4.2 Live, on a pty and a real terminal (run, results below)

| Check | Result |
|---|---|
| List fills while the header says `scanning…`; a folder marked `…` fills in | ✅ |
| Home menu finds disks, Podman machines, every `kubectl` context | ✅ |
| `d` then `⏎` on a throwaway folder | ✅ moved to the Trash, `keep/` untouched, footer said so |
| `D` then `⏎` | ✅ refused; only `y` deletes |
| Low-Hanging Fruits | ✅ 20 targets, 10.2 GiB, blocked rows explained, nothing emptied without `y` |
| `/` find, `T` largest, `A` cold, `c` briefing to the clipboard | ✅ |
| `chmod 000` folder | ✅ row reads `locked/  (unreadable)`, header carries the lower-bound caveat, inside it says permission denied + Full Disk Access |
| **CPU once the scan is done** | ✅ **0.01 s over 8 s idle (~0.1 % of a core)** — was 1.2–5.7 % at a fixed 10 Hz |
| `q`, then Ctrl-C | ✅ exit 0, terminal cooked, alternate screen left |
| `kill -INT` | ✅ terminal restored, process dies of the signal |
| Terminal closed (pty master closed) | ✅ dies of `SIGHUP` — no longer a silent exit 0 |
| `kill -TSTP` then `kill -CONT` | ✅ alternate screen left on stop, re-entered and repainted on resume |
| `TERM=dumb` / `TERM` unset | ✅ exit 2 with a message pointing at `--scan` / `--briefing` |
| `--tui -x` | ✅ usage, exit 2 (was: silently scanned `$HOME`) |

Not covered: a visual pass in Terminal.app/iTerm2 with an *ambiguous = wide* CJK profile (the reason `SPACEMATTERS_TUI_ASCII` exists), and ssh.

### 4.3 Cross-check

The header's totals at the end of a scan against `--scan` on the same path.

## 5. Risks & assumptions (🔬)

- 🔬 **Cell widths** cover the East Asian Wide blocks and emoji presentation, not all of UAX #11. Ambiguous-width characters are counted as one cell; a terminal configured to draw them wide clips the line end rather than wrapping (autowrap off), and `SPACEMATTERS_TUI_ASCII=1` is the way out.
- 🔬 `pthread_sigmask` blocks the handled signals on the thread doing the termios work only. An asynchronous signal can still be delivered to another thread, which is why the handler is written to be correct on its own rather than relying on the mask.
- 🔬 A folder is marked unreadable when `open(2)` refuses it. A directory that opens but fails partway through (a dying mount) still only raises the scan-wide `skipped` count.
- 🔬 `DispatchQueue.main.sync` from the frame thread assumes the main run loop is alive. It is started before the frame thread and never stopped; the process exits from the frame loop, after restoring the terminal.
- 🔬 **Unverified: whose Full Disk Access applies.** macOS privacy protection attributes a process started from Terminal.app (or `sshd`) to that terminal as its *responsible* process, unless the terminal disclaims it; so the app bundle's grant most likely does not reach `SpaceMatters --tui` launched from a shell, and the terminal's own grant is what counts. The UI says so ("Full Disk Access for the terminal this runs in"), and either way an unreadable folder is flagged and every total called a lower bound. Same open question as SPEC-14 §6 for `--mcp`.

## 6. Next, in order of value per line of code

1. **Multi-select** in the browser (`x` to mark, one confirmation for the batch) — the window has it (⌘⌫); the terminal deletes one row at a time.
2. **Verdict marks** from an MCP session shown in the rows, so a terminal and an assistant can look at the same tree.
3. **`--tui --vm podman` / `--tui --k8s <ctx>`** — argument parsing over routes that already exist.
4. **OSC 52** as a clipboard fallback for `c` over `ssh`, where `NSPasteboard` is the wrong machine's.
5. **A pty-driven integration test** in CI: the frame loop and the termios session are exercised by hand today (§4.2), and only their pure parts — the diff, the tick, the decoder — are under `swift test`.
