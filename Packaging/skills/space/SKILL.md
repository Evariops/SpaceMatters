---
name: space
description: Analyse what is filling a Mac's disk and produce a delete plan, using the SpaceMatters MCP server. Use when the user asks why their disk is full, what is taking up space, what they can safely delete, or asks to clean up / free up disk space.
---

# Disk space analysis

The `spacematters` MCP server exposes one filesystem scan, read-only. It measures;
you classify. It knows how many bytes are in a folder and when they were last
written — it does not know that `workspaceStorage` holds state for repositories
deleted two years ago, or that 38 GiB of `.raw` is a photo library that belongs
on an external drive. That judgement is the entire value you add.

## Procedure

1. **`overview` first, always.** One call returns the totals, the exact file-type
   table, and a size-budgeted tree. Read it before calling anything else.
2. **`find` before you drill.** Patterns scattered across the disk almost always
   reorder the priorities: `node_modules`, `.venv`, `target`, `build`, `bin`,
   `obj`, `DerivedData`, `__pycache__`, `.gradle`. One `node_modules` is 400 MB
   and invisible in a tree; nineteen of them are 6.7 GiB and the top finding.
   Nested matches are counted once, so the total is honest.
3. **Drill the top three by share** with `tree`. Detail follows size, not depth.
4. **`aged` for every candidate.** Regenerable *and* cold is the only signal
   strong enough to act on unprompted. A build cache written yesterday is in
   active use; the same cache untouched for a year is dead weight. `aged`
   reports the outermost cold folder only — everything inside one is at least
   as cold.
5. **`explain` before proposing anything.** It tells you whether the folder is a
   target SpaceMatters cleans itself, whether its size is real or sparse, and
   when it was last written.
6. **`annotate` as you go**, whenever the tool is offered (it appears only when
   the app is running). This is how a conclusion reaches the user: the folder
   and its whole region take the verdict's colour on their treemap, with your
   reason on hover. A finding that exists only in this transcript is a finding
   they have to re-read; one on the map is one they can see.

## Reading the numbers

- **Sizes are on-disk bytes** — allocated blocks, what deleting actually frees.
- **`apparent` far above on-disk means sparse or compressed.** A 512 GiB VM
  image occupying 64 MiB is correct, not a bug. Never quote the apparent size as
  what deleting would free; `explain` spells out the cause.
- **`cold:8mo` is inherited**, not repeated: it means nothing anywhere in that
  subtree has been written for that long, and everything nested inside is at
  least as cold. No mark means recent — or timestamps unknown, which happens on
  VM and SSH scans.
- **`types` is exact only for the whole scan.** For a subtree it is
  reconstructed from per-folder dominant types: the ranking is reliable, the
  individual totals are not. Never quote a subtree figure as measured.
- **`find` matches directory names only.** Files are not tracked individually,
  so `*.raw` finds nothing — use `types` for file extensions.
- **A note about unreadable locations means the totals are lower bounds.**
  Say so in your conclusions rather than presenting them as complete.

## Safety rules

- **Never propose `rm -rf` for a path `explain` reports as a cleanup target.**
  SpaceMatters empties those itself, fenced to the user's home, never following
  symlinks, and journalled. Point at Low-Hanging Fruits in the app instead.
  This covers more than a fixed list: `bin`/`obj`/`target` beside a project
  file, and orphaned editor workspace state, are recognised too.
- **`explain` also answers "NOT a cleanup target", and that answer outranks
  your own reading.** It is how you learn that a `bin/` is a virtualenv's, or
  that a `workspaceStorage` folder belongs to a project still on disk. A
  directory that looks obviously disposable from its name and size is exactly
  the case this exists for.
- **Never call anything "safe" that you have not run `explain` on.**
- **Check whether the owning app is running** before recommending an app's
  cache. Its files are held open; deleting them frees nothing until quit.
- **Documents, photos, music and videos are never `safe`.** They are `review`
  at most, and the recommendation is to move them, not to delete them.
- **Application Support is not a cache directory.** Some of it is state the app
  cannot refetch. See `references/directories.md` before touching any of it.
- The server cannot delete anything and neither should you. Produce a plan; the
  user acts on it.

## Output

A table, most bytes first:

| Path | Size | Verdict | Why | How |
|---|---|---|---|---|

- **Why** is the evidence, not a restatement of the size: what the folder is,
  when it was last written, whether it regenerates.
- **How** is the concrete action: the app's cleanup pass, a shell command, a
  tool's own command (`docker system prune`, `git gc`, `brew cleanup`), or
  "move to external drive".
- Total up what the plan actually frees, and be honest about the uncertainty
  when locations were unreadable.

Then call `annotate` once per row so the plan is on their map too.

## Reference

`references/directories.md` — what the usual suspects on a Mac actually are,
which regenerate, and which look like caches but hold state.
