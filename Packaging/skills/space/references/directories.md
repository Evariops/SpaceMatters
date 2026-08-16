# What the usual suspects on a Mac actually are

The scanner gives bytes and dates. This is the part it cannot give you. When a
folder is not listed here, say you are unsure rather than guessing — an
authoritative-sounding wrong answer about someone's disk is the failure mode
that matters.

## Regenerates on demand — safe when cold

| Path | What it is | Cost of deleting |
|---|---|---|
| `~/Library/Caches/Homebrew`, `~/Library/Caches/homebrew` | Downloaded bottles and casks | Re-download. `brew cleanup` is the tool's own way. |
| `~/.npm/_cacache` | npm's content-addressable cache | Re-download. `npm cache clean --force`. |
| `~/Library/Caches/Yarn`, `~/Library/pnpm/store`, `~/.pnpm-store` | JS package stores | Re-download. pnpm's store is shared by every project — deleting it forces a refetch for all of them. |
| `~/.cargo/registry` | Rust crate sources and caches | Re-download. `~/.cargo/bin` is **not** this: it holds installed binaries. |
| `~/go/pkg/mod`, `~/Library/Caches/go-build` | Go module cache and build cache | Re-download / rebuild. `go clean -modcache`, `go clean -cache`. |
| `~/.m2/repository`, `~/.gradle/caches` | JVM dependency caches | Re-download, and these are slow to refill. |
| `~/.nuget/packages` | NuGet packages | Re-download. |
| `~/Library/Caches/pip`, `~/Library/Caches/uv` | Python wheel caches | Re-download. |
| `~/Library/Developer/Xcode/DerivedData` | Per-project build products, indexes | Rebuild, and the first build after is slow. |
| `~/Library/Caches/org.swift.swiftpm`, `~/Library/Caches/CocoaPods` | Dependency caches | Re-download. |
| `~/.npm/_npx` | Throwaway install tree per `npx <pkg>`, never evicted | Re-download. Routinely larger than `_cacache` — check both. |
| `node_modules`, `.venv`, `target`, `build`, `bin`, `obj`, `__pycache__`, `.next`, `dist` | Per-project build/dependency trees | Reinstall or rebuild. Individually small, collectively often the single largest finding — always `find` them. |

### `bin/` and `obj/` are not safe by name

On a .NET machine these are usually the largest single finding — 20 GiB across
1,722 folders on a real disk. They are also the most dangerous name to sweep: a
Python virtualenv keeps its interpreter, `pip` and `activate` in `bin/`, and Go
projects keep compiled binaries there. A bare
`find ~ -type d -name bin -exec rm -rf {} +` destroys every virtualenv on the
disk.

What makes one safe is a **sibling project file** — `*.csproj`, `*.fsproj`,
`*.sln` next to the `bin/`, `Cargo.toml` next to a `target/`. Run `explain` on
any such folder: SpaceMatters applies exactly that rule and tells you which side
the folder falls on. It cleans the qualifying ones itself.

Do **not** recommend `dotnet clean` as the tidy alternative. It cleans one
configuration of one project, leaves `Release/` and `project.assets.json` in
place (measured: 28% of `bin`+`obj` freed on a two-configuration build), needs a
restore, and fails outright when a `global.json` pins an SDK that is not
installed. Removing the directory is both more complete and faster.

## Grows without bound, nobody notices

- **`~/Library/Application Support/Code/User/workspaceStorage`** — one folder per
  workspace VS Code has ever opened, keyed by a hash. Frequently gigabytes, and
  the single most misjudged directory on this list. Two things are true at once
  and both get missed:

  1. **The bulk of it is AI chat transcripts.** On a real machine: 7.9 GiB
     `chatSessions` + 1.2 GiB `chatEditingSessions` out of 10.7 GiB — 85%.
     Nothing regenerates those. "It only costs editor layout and undo history"
     is simply false; never write it.
  2. **Most folders are still live.** The folder does keep state for deleted
     repositories, but far less than it looks: 9 of 192 on the same machine,
     0.11 GiB of the 10.7. "Most of these belong to repos you deleted long ago"
     is an assumption, and measuring it takes one read per folder.

  Each hash folder holds a `workspace.json` naming the project it belongs to, so
  orphan status is *decidable*, not a guess. Run `explain` on the directory —
  SpaceMatters counts live vs orphaned workspaces for you — and never propose
  emptying the whole thing. The app offers the orphaned folders only.
- **`~/Library/Caches/JetBrains/<Product><Version>`** — one tree per IDE version
  ever installed. Old versions are pure waste once uninstalled; the current one
  regenerates but reindexing is slow. `~/Library/Application Support/JetBrains`
  is different: settings and installed plugins, not a cache.
- **`~/Library/Developer/CoreSimulator/Devices`** — every simulator ever created,
  each a full disk image. `xcrun simctl delete unavailable` removes the ones
  tied to runtimes you no longer have.
- **`~/Library/Developer/Xcode/iOS DeviceSupport`** — symbol caches per device
  and iOS version, one folder per combination, regenerated on next connect.
- **Electron app caches** (`Slack`, `Notion`, `Discord`, …) under
  `Application Support/<app>/{Cache, Code Cache, GPUCache, Service Worker}` —
  refetched. Their siblings are not: see below.
- **`~/Library/Caches` as a whole is not one thing.** It mixes three
  populations: per-app caches keyed by bundle id (`us.zoom.xos`,
  `com.tinyspeck.slackmacgap`), developer tool caches with plain names
  (`colima`, `trivy`, `goimports`, `ms-playwright`), and system state that is
  not an app cache at all (`CloudKit`, `com.apple.*`). Never recommend emptying
  the directory; name the subdirectories.

  **Check whether the owning app is running before recommending its cache.** A
  desktop app holds its cache open for hours, so unlinking underneath it frees
  nothing until quit and can leave the app's own index pointing at files that no
  longer exist. This is a real case, not a hypothetical: Chrome, Firefox, Slack
  and Zoom caches are often several GB and those apps are usually open.
  SpaceMatters blocks such a target while its app runs — recommend quitting
  first, or point at the app's cleanup pass.

  `ms-playwright` deserves its own wording: it is browser *binaries*, not
  fetched assets. Nothing re-downloads them on demand, and every e2e test fails
  until `npx playwright install` is run by hand. Regenerable, but not
  automatically — say so.

## Looks like a cache, holds state

Deleting these loses data the app cannot get back.

- **A tool's `~/.cache/<name>` and its `~/.local/share/<name>` are opposites**,
  and the matching names invite exactly the wrong conclusion. opencode is the
  worked example: `~/.cache/opencode` is downloaded helper binaries and a model
  list (disposable), while `~/.local/share/opencode` holds `auth.json` and
  `opencode.db` — the login token and every conversation. Never generalise a
  verdict from one to the other because the tool's name matches; check which of
  the two you are looking at. The same split applies to most XDG-shaped tools:
  `.cache` is disposable, `.local/share` and `.config` are not.

- `Application Support/*/IndexedDB`, `Local Storage`, `Session Storage`,
  `Databases` — app state, drafts, unsynced edits.
- `Application Support/*/File System`, `blob_storage` — offline attachments.
- `Cookies`, `Login Data` — logs the user out of everything.
- Browser **profiles** (`Firefox/Profiles/*`, `Chrome/Default`): the `Cache`,
  `Code Cache` and `Service Worker/CacheStorage` inside them are safe; the
  profile as a whole is history, passwords, extensions and open tabs. Never
  recommend deleting a profile directory.
- `~/Library/Containers/<bundle-id>/Data` — a sandboxed app's entire home. Not a
  cache in any sense.
- `~/Library/Mail`, `~/Library/Messages` — the actual mail and messages.

## Never "safe"

- **Photo and video libraries** (`.photoslibrary`, folders of `.raw`, `.dng`,
  `.mov`, `.mp4`). A `.photoslibrary` contains a `resources/caches` subtree that
  looks deletable and is not — it is managed by Photos. The right advice for a
  large media library is to move it to an external drive, or to offload
  originals to iCloud, never to delete.
- **`.git`** — and especially not `.git/objects` or `*.pack` files, which *are*
  the repository. When a `.git` is genuinely huge, the answer is `git gc
  --aggressive --prune=now`, or `git worktree`/shallow clones going forward.
- **Time Machine local snapshots** — they show as disk usage and are managed by
  the system, which reclaims them under pressure. `tmutil thinlocalsnapshots`
  exists, but macOS handles this on its own; recommending manual deletion is
  rarely right.
- Anything under `/System`, `/private/var/db`, or another user's home.

## Sparse — the size is not what you think

Container and VM disk images declare a huge length and allocate a fraction of
it: `~/.colima`, `~/.lima`, `~/Library/Containers/com.docker.docker`,
`~/Library/Application Support/com.apple.container`, Parallels and VMware
bundles, `.ext4`/`.raw`/`.qcow2` files. `explain` reports the gap. Deleting
frees the on-disk figure, not the apparent one — and the tool's own reclaim
command (`docker system prune`, `podman system prune`, `colima delete`) is
almost always the better answer than removing files under it.

**Pruning inside a VM does not shrink its disk image — but that does not mean
the space is lost.** The guest frees the blocks; the host file keeps them
allocated until the guest issues a discard for them. So a `podman system prune`
that reclaims 15 GB inside can leave the `.raw` byte-for-byte as large as
before. Do not conclude from this that "podman disks only grow, recreate the
machine": Podman's applehv backend passes discard through (`lsblk -D` in the
guest shows a non-zero `DISC-MAX`), and Fedora CoreOS runs `fstrim.timer`
weekly. The blocks come back — just up to a week late.

The right sequence is prune, then trim: SpaceMatters' container mode has a
**Reclaim host disk** button that runs `fstrim` in the machine and reports the
measured change in the image file. By hand it is
`podman machine ssh sudo fstrim /var`. Two cautions:

- Never quote `fstrim`'s own output as space recovered. It prints the size of
  the free extents it walked — "39.5 GiB trimmed" for 2.06 GB actually returned,
  measured. Only the image file's on-disk size before and after is the truth.
- `podman machine set --disk-size` grows a machine and cannot shrink one; there
  is no resize path here, and none is needed, because the file is sparse.
