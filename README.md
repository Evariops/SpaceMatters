# MacDirStats

A fast, modern macOS disk-usage visualizer — like WinDirStat, rebuilt for macOS
with an obsession for **scan speed**, **live UI feedback**, and **low memory use**.

![dark](https://img.shields.io/badge/theme-dark--first-0E1116) ![swift](https://img.shields.io/badge/Swift-6-orange) ![macOS](https://img.shields.io/badge/macOS-15%2B-blue)

## Highlights

- **~220,000 files/second.** Measured: 801k files / 133k folders / 94 GB scanned in **3.6 s** on an Apple Silicon SSD.
- **~35 MB peak RAM** for that same 800k-file scan.
- **Live treemap + folder list** that fill in *during* the scan, not after.
- **Dark theme first**, with a light toggle. Hand-built palette, no system-material guesswork.
- Squarified treemap, sortable directory outline, and a file-type (extension) breakdown.

## How it's fast and lean

| Concern | Approach |
|---|---|
| Scan speed | [`getattrlistbulk(2)`](Sources/MacDirStats/Scanner/FSAttr.swift) — one syscall returns many directory entries *with* sizes, avoiding `readdir`+`stat` per file. A LIFO worker-thread pool walks subtrees in parallel. |
| Low RAM | One node **per directory only** ([`FSNode`](Sources/MacDirStats/Model/FSNode.swift)); files collapse into per-directory aggregates. Object count tracks *folders*, not *files*. |
| Per-extension stats | [`ExtKey`](Sources/MacDirStats/Model/ExtKey.swift) packs the extension into two `UInt64`s inline — **zero `String` allocations per file**. |
| Live UI | Sizes are atomics propagated up the ancestor chain as each directory completes; the UI re-reads them at 10 Hz. |

## Build & run

```bash
# Build a double-clickable app bundle
./bundle.sh
open MacDirStats.app

# …or run directly during development
swift run -c release
```

Pick a folder with **Open Folder** (⌘O) and watch it fill in.

### Headless mode (benchmark / scripting)

```bash
swift build -c release
.build/release/MacDirStats --scan /some/path
```

Prints totals, timing, throughput, and the top file types.

## Using the UI

- **Left:** live directory outline (sorted by size) over a file-type breakdown.
- **Right:** squarified treemap. **Hover** for a path + size tooltip, **click**
  to select, **double-click** a folder to zoom in. Zoom back out with the
  **↖︎** breadcrumb button, **⌘↑**, or a **double-click** on empty space.
  **Right-click** any tile for Reveal in Finder / Copy Path / Move to Trash.
- **On disk / Logical** toggle switches between allocated and content size.
- Sun/moon toggles the theme.

## Notes & current limits

- Size accuracy: the physical (on-disk) total matches `du -skx` exactly in
  testing — the scan stays on the volume you picked and does not cross into
  mounted filesystems (swap, Preboot, external disks, DMGs), matching `du -x`.
- Symlinks are counted by their own size and **not** followed (no cycles).
- Hard-linked files are counted once per link (same as WinDirStat).
- Scanning system locations may require granting access; per-entry permission
  errors are skipped and surfaced as a "skipped" count.
- The treemap is directory-granular (files aggregate per folder) — a deliberate
  RAM trade-off. Per-file treemap detail is a possible future addition.

## Requirements

macOS 15+, Swift 6 toolchain (Xcode 16+).
