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
| `node_modules`, `.venv`, `target`, `build`, `bin`, `obj`, `__pycache__`, `.next`, `dist` | Per-project build/dependency trees | Reinstall or rebuild. Individually small, collectively often the single largest finding — always `find` them. |

## Grows without bound, nobody notices

- **`~/Library/Application Support/Code/User/workspaceStorage`** — one folder per
  workspace VS Code has ever opened, keyed by a hash. Holds editor state, chat
  sessions (`chatSessions`, `.jsonl`) and per-extension databases (`.vscdb`).
  **It keeps folders for repositories deleted years ago** and never prunes them.
  Frequently gigabytes. Deleting a hash folder loses that workspace's local
  history and chat transcripts, not the code — that is the real trade-off to
  present, not "it's a cache".
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

## Looks like a cache, holds state

Deleting these loses data the app cannot get back.

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
