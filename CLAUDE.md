# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

Requires **Zig 0.15.2**. No external dependencies — SQLite 3.47.2 is vendored in `deps/sqlite/`.

```bash
zig build              # builds zig-out/bin/agx
zig build test         # runs all unit tests (co-located in source files)
zig build run -- <cmd> # build and run, e.g. zig build run -- exploration status
```

Tests are embedded in source files (not in `test/`). `src/agx.zig` uses `testing.refAllDecls` to pull in all module tests transitively. Files with tests: `store.zig`, `ulid.zig`, `ingest.zig`, `json_writer.zig`.

## What agx Does

Agent-aware version control layered on git. When multiple AI agents work the same goal in parallel worktrees, agx tracks each task's sessions, events, and evidence, then helps compare results and merge the best one back.

**Data hierarchy:** Goal → Task → Session → Event (plus Evidence and Snapshot off Session/Task).

**Storage:** `.git/agx/db.sqlite3` (SQLite, local/untracked). Context exports go to `.agx/context/` (tracked/shared).

## Architecture

### CLI dispatch
`src/main.zig` — `std.StaticStringMap` maps top-level command names to handler functions. `exploration` and `dispatch` are subcommand routers (see `src/cli/exploration.zig`, `src/cli/dispatch.zig`). All commands share the signature `fn run(Allocator, []const[]const u8, *std.Io.Writer, *std.Io.Writer) anyerror!void`. Stdout/stderr are 4KB-buffered and must be explicitly flushed.

### Module layers
- **`src/core/`** — Entity structs (Goal, Task, Session, Event, Evidence, Snapshot, Dispatch) + ULID. Pure data, no I/O.
- **`src/storage/`** — `Store` wraps SQLite. `migrations.zig` runs versioned schema changes. `export.zig` writes context files.
- **`src/git/cli.zig`** — `GitCli` shells out to `git` binary. All ops accept optional repo path.
- **`src/cli/`** — One file per command + `cli_common.zig` (`CliContext` bundles git/store init). `exploration.zig` and `dispatch.zig` are subcommand routers.
- **`src/compare/`** — `metrics.zig` collects per-task stats, `renderer.zig` outputs table or JSON.
- **`src/daemon/`** — `ingest.zig` parses JSONL event files, `file_watcher.zig` polls for new data.
- **`src/util/`** — `json_writer.zig` (shared streaming JSON writer with comma tracking).
- **`src/sqlite.zig`** — Hand-written Zig bindings for the vendored SQLite C API.
- **`src/agx.zig`** — Library root, re-exports all submodules.

### Key patterns

**Arena allocators** — Every CLI command creates `ArenaAllocator`, passes `arena.allocator()` through. Single `defer arena.deinit()` frees everything. Core structs do NOT have `deinit` methods.

**Fixed-size stack buffers for queries** — Store methods take caller-supplied `buf: []T` (e.g., `var buf: [32]Task = undefined`). No dynamic allocation in query paths.

**Cached prepared statements** — Five hot-path SQLite statements are cached on the `Store` struct and reused via `getCached()` with reset. Methods with dynamic SQL (e.g., filtered queries) still use one-shot prepare/finalize.

**Enum conversion** — All enums implement `toStr()` (returns `@tagName`) and `fromStr()` (uses `inline for` over `@typeInfo(...).@"enum".fields`).

**`CliContext`** (`cli_common.zig`) — Opens git dir, constructs DB path, opens store. Most commands use this; worktree-aware commands (`done`, `approach`, `evidence`, `record`) use `WorktreeContext` from `session_util.zig` instead.

**`JsonWriter`** — Tracks comma state internally. Use `beginObject`/`endObject`, field methods like `stringField`, `intField`, `rawField`. For JSONL output, create a fresh `JsonWriter` per line.

### Dispatch workflow
- `dispatch create` creates goals + worktrees + branches (`agx/dispatch-{id}/{index}`)
- `dispatch merge` squash-merges goals sequentially in least-overlap-first order, tracking progress in `merge_progress`
- `dispatch merge --continue` resumes after conflict resolution (commits the resolved merge, advances progress)
- `dispatch cancel` aborts any in-progress merge and sets dispatch status to `abandoned`
- `DispatchStatus` enum: `active` → `merging` → `completed` | `conflict` | `failed` | `abandoned`

### Git conventions
- Branch naming: `agx/{goal_id_short_6}/{index}` (e.g., `agx/01JK7M/2`), dispatch branches: `agx/dispatch-{dispatch_id}/{index}`
- Commit trailers: `AGX-Goal`, `AGX-Task`, `AGX-Agent`, `AGX-Model`, `AGX-Dispatch`
- Agent event files: `.git/agx/events/{session_id}.jsonl`
- Session discovery: `.agx-session` file in each worktree root

## When attempting to address multiple tasks

You MUST use the multi-agent workflow — do NOT implement multiple tasks yourself sequentially. Invoke the appropriate skill BEFORE exploring the codebase or reading source files. After invoking the skill, follow it step by step without deviation.

- **`/agx-explore-lead`** — The user is giving one problem to solve and is asking to try different approaches or ways of implementing the solution. This skill includes instruction to spawn an agent team to try different approaches, compare results, and merge the winner.
- **`/agx-batch-lead`** — The user is giving a list of problems to solve or features to implement (where there might be code overlap). This skill includes instructions to spawn an agent team to solve the list of tasks stated by the user, each agent taking one task each, and then merging everyone's changes sequentially.

## Zig 0.15 Notes

- `std.Io.Writer` is the virtual-dispatch writer interface (replaces old `anytype` pattern in some contexts)
- `usingnamespace` is removed — no comptime mixins
- Use `gw.adaptToNewApi(&buf)` to get `*std.Io.Writer` from a `GenericWriter` in tests
- `std.ArrayList(T)` uses `.empty` for initialization and takes allocator per-call (e.g., `.append(alloc, item)`)
