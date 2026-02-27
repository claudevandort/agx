# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

Requires **Zig 0.15.2**. No external dependencies — SQLite 3.47.2 is vendored in `deps/sqlite/`.

```bash
zig build              # builds zig-out/bin/agx
zig build test         # runs all unit tests (co-located in source files)
zig build run -- <cmd> # build and run, e.g. zig build run -- status
```

Tests are embedded in source files (not in `test/`). `src/agx.zig` uses `testing.refAllDecls` to pull in all module tests transitively. Files with tests: `store.zig`, `ulid.zig`, `ingest.zig`, `json_writer.zig`.

## What agx Does

Agent-aware version control layered on git. When multiple AI agents work the same task in parallel worktrees, agx tracks each exploration's sessions, events, and evidence, then helps compare results and merge the best one back.

**Data hierarchy:** Task → Exploration → Session → Event (plus Evidence and Snapshot off Session/Exploration).

**Storage:** `.git/agx/db.sqlite3` (SQLite, local/untracked). Context exports go to `.agx/context/` (tracked/shared).

## Architecture

### CLI dispatch
`src/main.zig` — `std.StaticStringMap` maps command names to handler functions. All commands share the signature `fn run(Allocator, []const[]const u8, *std.Io.Writer, *std.Io.Writer) anyerror!void`. Stdout/stderr are 4KB-buffered and must be explicitly flushed.

### Module layers
- **`src/core/`** — Entity structs (Task, Exploration, Session, Event, Evidence, Snapshot) + ULID. Pure data, no I/O.
- **`src/storage/`** — `Store` wraps SQLite. `migrations.zig` runs versioned schema changes. `export.zig` writes context files.
- **`src/git/cli.zig`** — `GitCli` shells out to `git` binary. All ops accept optional repo path.
- **`src/cli/`** — One file per command + `cli_common.zig` (`CliContext` bundles git/store init).
- **`src/compare/`** — `metrics.zig` collects per-exploration stats, `renderer.zig` outputs table or JSON.
- **`src/daemon/`** — `ingest.zig` parses JSONL event files, `file_watcher.zig` polls for new data.
- **`src/util/`** — `json_writer.zig` (shared streaming JSON writer with comma tracking).
- **`src/sqlite.zig`** — Hand-written Zig bindings for the vendored SQLite C API.
- **`src/agx.zig`** — Library root, re-exports all submodules.

### Key patterns

**Arena allocators** — Every CLI command creates `ArenaAllocator`, passes `arena.allocator()` through. Single `defer arena.deinit()` frees everything. Core structs do NOT have `deinit` methods.

**Fixed-size stack buffers for queries** — Store methods take caller-supplied `buf: []T` (e.g., `var buf: [32]Exploration = undefined`). No dynamic allocation in query paths.

**Cached prepared statements** — Five hot-path SQLite statements are cached on the `Store` struct and reused via `getCached()` with reset. Methods with dynamic SQL (e.g., filtered queries) still use one-shot prepare/finalize.

**Enum conversion** — All enums implement `toStr()` (returns `@tagName`) and `fromStr()` (uses `inline for` over `@typeInfo(...).@"enum".fields`).

**`CliContext`** (`cli_common.zig`) — Opens git dir, constructs DB path, opens store. Most commands use this; worktree-aware commands (`done`, `approach`, `evidence`, `record`) use `WorktreeContext` from `session_util.zig` instead.

**`JsonWriter`** — Tracks comma state internally. Use `beginObject`/`endObject`, field methods like `stringField`, `intField`, `rawField`. For JSONL output, create a fresh `JsonWriter` per line.

### Git conventions
- Branch naming: `agx/{task_id_short_6}/{index}` (e.g., `agx/01JK7M/2`)
- Commit trailers: `AGX-Task`, `AGX-Exploration`, `AGX-Agent`, `AGX-Model`
- Agent event files: `.git/agx/events/{session_id}.jsonl`
- Session discovery: `.agx-session` file in each worktree root

## Parallel Explorations

To run parallel agent explorations of a task, invoke the `/agx-lead` skill. It contains full instructions on spawning explorations, launching agent teams, comparing results, and merging the winner.

## Zig 0.15 Notes

- `std.Io.Writer` is the virtual-dispatch writer interface (replaces old `anytype` pattern in some contexts)
- `usingnamespace` is removed — no comptime mixins
- Use `gw.adaptToNewApi(&buf)` to get `*std.Io.Writer` from a `GenericWriter` in tests
- `std.ArrayList(T)` uses `.empty` for initialization and takes allocator per-call (e.g., `.append(alloc, item)`)
