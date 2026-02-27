# agx Code Review (Critical issues 1-3, High-priority issues 4-8 fixed)

Comprehensive review of the agx codebase (~4,200 lines of Zig 0.15 across 33 source files).

---

## Critical Issues

### 1. JSON output is never escaped

**Files:** `src/compare/renderer.zig:194`, `src/storage/export.zig`, `src/cli/log.zig:135-139`

`jsonEscape()` in `renderer.zig` is a no-op — it returns the input unchanged. All JSON output across the codebase embeds string values via `{s}` format specifiers with no escaping of `"`, `\`, newlines, or control characters. This produces **malformed JSON** whenever any field (task description, approach, summary, evidence summary, event data) contains these characters.

Affected output paths:
- `agx compare --format json`
- `agx log --json`
- `sessions.jsonl` and `evidence.json` in exported context

**Fix:** Implement a proper `jsonEscapeWrite` function that writes escaped output to a writer, or use `std.json.encodeJsonString`. Every `{s}` inside a JSON string literal in the codebase needs to go through escaping.

### 2. Memory leaks on partial read failures in store.zig

**File:** `src/storage/store.zig` — `readTask`, `readExploration`, and all `read*` helpers

When `dupeText`/`dupeOptionalText` fails partway through reading a row, previously duped fields leak. For example, in `readTask`: if `description` and `base_commit` are duped successfully but `base_branch` fails, the first two allocations are never freed. There are no `errdefer` guards on intermediate allocations.

The same pattern applies to all multi-row readers (`getExplorationsByTask`, `getSessionsByExploration`, etc.) — if `readExploration` fails at index k, entries `0..k-1` have heap-allocated fields that leak.

**Fix:** Add `errdefer` for each intermediate allocation in read helpers, or restructure to use an arena allocator for query results.

### 3. `undefined` used instead of `null` in ULID test

**File:** `src/core/ulid.zig:136`

```zig
const id = Ulid.fromParts(1700000000000, undefined);
```

Passing `undefined` for a `?[10]u8` optional does not set it to `null` — it leaves the discriminant indeterminate. The `if (random) |r|` branch in `fromParts` has **undefined behavior**. This should be `null`.

---

## High-Priority Issues

### 4. No `deinit` methods on domain structs — cleanup duplicated everywhere

**Files:** All `src/core/*.zig` structs, all `src/cli/*.zig` commands

The exact same free-field pattern is copy-pasted across 6+ files for each struct type:

```zig
// This block appears in spawn, status, compare, keep, archive, discard, log, clean, export...
defer for (exps) |e| {
    alloc.free(e.worktree_path);
    alloc.free(e.branch_name);
    if (e.approach) |a| alloc.free(a);
    if (e.summary) |s| alloc.free(s);
};
```

Similar patterns exist for `Task` (5 files), `Session` (4 files), `Evidence` (3 files), and `Event` (3 files).

**Fix:** Add `deinit(alloc: Allocator)` to each domain struct and a `freeSlice(alloc, slice)` helper:

```zig
pub const Exploration = struct {
    // ... fields ...
    pub fn deinit(self: *const Exploration, alloc: Allocator) void {
        alloc.free(self.worktree_path);
        alloc.free(self.branch_name);
        if (self.approach) |a| alloc.free(a);
        if (self.summary) |s| alloc.free(s);
    }

    pub fn deinitSlice(alloc: Allocator, slice: []const Exploration) void {
        for (slice) |*e| e.deinit(alloc);
    }
};
```

### 5. CLI boilerplate duplicated in 9 of 15 command files

**Files:** All CLI commands except `init.zig`, `done.zig`, `approach.zig`, `record.zig`, `session_util.zig`

~15 lines of identical git-dir/db-path/store-init code is repeated in every command:

```zig
const git = agx.GitCli.init(alloc, null);
const git_dir = git.gitDir() catch { ... };
defer alloc.free(git_dir);
const db_path = try std.fmt.allocPrintSentinel(alloc, "{s}/agx/db.sqlite3", .{git_dir}, 0);
defer alloc.free(db_path);
std.fs.cwd().access(db_path[0..db_path.len :0], .{}) catch { ... };
var store = try agx.Store.init(alloc, db_path);
defer store.deinit();
```

**Fix:** Extract into a shared `cli_common.zig` returning a context struct, similar to what `session_util.zig` does for worktree commands.

### 6. `toStr`/`fromStr` boilerplate on every enum

**Files:** `task.zig`, `exploration.zig`, `session.zig`, `event.zig`, `evidence.zig` (×2)

Six enums each manually implement the same pattern of matching against string literals. This is ~120 lines of code that could be replaced by a single comptime helper using `@tagName` and `std.meta.fields`:

```zig
pub fn StringSerializable(comptime E: type) type {
    return struct {
        pub fn toStr(val: E) []const u8 {
            return @tagName(val);
        }
        pub fn fromStr(s: []const u8) !E {
            inline for (std.meta.fields(E)) |f| {
                if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
            }
            return error.InvalidValue;
        }
    };
}
```

Note: `@tagName` on `@"error"` correctly returns `"error"`, so escaped identifiers work.

### 7. `init.zig` writes errors to stdout instead of stderr

**File:** `src/cli/init.zig:6,18,39,52,62`

`stderr` is explicitly discarded (`_ = stderr`) and all error messages go to `stdout`. Every other command correctly uses `stderr` for errors.

### 8. Migrations are not transactional

**File:** `src/storage/store.zig:45-67`

The `migrate()` function applies DDL via `execMulti` then inserts a version record, but there is no `BEGIN`/`COMMIT` wrapper. If the version INSERT fails after the DDL succeeds, the schema is modified but unrecorded — the migration will be re-attempted on next init, likely failing or causing duplication.

**Fix:** Wrap each migration in a transaction.

---

## Medium-Priority Issues

### 9. Global mutable state in renderer.zig

**File:** `src/compare/renderer.zig:198`

```zig
var duration_buf: [32]u8 = undefined;
```

File-level mutable buffer used by `fmtDuration`. If this function is ever called twice in the same expression (or from multiple threads), the buffer is overwritten before the first result is consumed. This is a latent reentrancy bug.

**Fix:** Pass a buffer parameter or use a local variable.

### 10. `renderFileOverlap` uses `page_allocator` directly

**File:** `src/compare/renderer.zig:113`

Bypasses the allocator discipline used everywhere else. `page_allocator` allocates in 4KB granularity — wasteful for a small hash map. Should accept an `Allocator` parameter.

### 11. Duplicate event risk from silently ignored offset persistence

**File:** `src/daemon/file_watcher.zig:43`

`store.setIngestOffset(...) catch {}` silently swallows failures. If the offset is not persisted, the next `scanAndIngest` call re-reads from the old offset and inserts duplicate events (each gets a new ULID, so uniqueness constraints don't help).

**Fix:** At minimum log a warning. Ideally, wrap the event inserts and offset update in a transaction.

### 12. `diffThreeWay` ignores `base` parameter

**File:** `src/git/cli.zig:208`

```zig
_ = base;
```

The function signature implies three-way diff but actually diffs `head1` vs `head2` directly. This is misleading and likely incomplete.

### 13. `runChecked` discards stderr on git failure

**File:** `src/git/cli.zig:65`

When a git command fails, the stderr output (which contains the actual error message) is freed before returning `error.GitCommandFailed`. The caller gets an opaque error with no diagnostic information.

**Fix:** Return the stderr message or log it before freeing.

### 14. Hand-rolled JSON parser in ingest.zig is fragile

**File:** `src/daemon/ingest.zig` — `extractStringValue`

Uses `indexOf` to find keys, which matches the first occurrence. If the key string appears inside an earlier JSON value, the wrong match is returned. Example: `{"data":"kind","kind":"actual"}` — searching for `"kind"` matches inside `"data"` first.

**Fix:** Use `std.json` for parsing, or at minimum track nesting depth.

### 15. Entire file read for incremental ingestion

**File:** `src/daemon/ingest.zig:100`

`readFileAlloc(alloc, file_path, 50 * 1024 * 1024)` reads the whole file into memory even when only the tail past `offset` is needed. For a daemon continuously ingesting large JSONL files, this is wasteful.

**Fix:** Seek to `offset` and read only new content.

### 16. Fixed-size stack buffers silently truncate results

**Files:** Multiple — used for all multi-row queries

| Buffer | Size | Location |
|--------|------|----------|
| `exp_buf` | `[32]Exploration` | status, compare, keep, archive, clean, export |
| `sess_buf` | `[8]Session` | keep, log, export |
| `ev_buf` | `[512]Event` / `[1024]Event` | log, export |
| `ev_buf` (evidence) | `[64]Evidence` | export, metrics |

If more rows exist than the buffer holds, extras are silently dropped with no warning. The user may see incomplete data.

**Fix:** Either document the limits clearly, return a "truncated" indicator, or use heap allocation for unbounded queries.

### 17. `@intCast` on potentially negative timestamp

**File:** `src/core/ulid.zig:13`

```zig
@intCast(std.time.milliTimestamp())
```

`milliTimestamp()` returns `i64`. On a misconfigured system clock returning a negative value, `@intCast` to `u64` triggers a safety-check panic in safe builds and UB in unsafe builds.

### 18. `std.process.exit(1)` prevents deferred cleanup

**Files:** All CLI commands

When commands hit an error and call `std.process.exit(1)`, all `defer` blocks in the call stack are skipped. This includes `store.deinit()`, `alloc.free()`, and GPA leak detection in `main.zig`. While the OS reclaims memory on exit, it means the GPA's leak detector never fires during error paths, and SQLite WAL checkpointing may be skipped.

**Fix:** Return errors to `main()` and let it handle exit, or accept this as a CLI trade-off and document it.

---

## Low-Priority / Style Issues

### 19. `status.zig` and `clean.zig` contain raw SQL queries

**Files:** `src/cli/status.zig:50-52,96-98`, `src/cli/clean.zig:23-25`

These bypass the `Store` abstraction, coupling CLI code directly to the database schema. All other queries go through `Store` methods.

### 20. Missing schema constraints

**File:** `src/storage/migrations.zig`

- No `UNIQUE(task_id, idx)` on `explorations` — duplicate indices per task are possible
- No `ON DELETE CASCADE` — orphaned rows remain if a parent is deleted
- No `CHECK` constraints on status values

### 21. No `--help` on individual commands

No command handles `--help` or `-h`. Usage is only shown on error.

### 22. Unknown flags are silently ignored

All argument parsers skip unrecognized flags without warning. `agx spawn --taks "foo"` silently ignores `--taks`.

### 23. `main.zig` command dispatch is a long if-else chain

14 commands dispatched via chained `if-else if` string comparisons (~90 lines). A `ComptimeStringMap` or lookup table would be more maintainable.

### 24. Unused imports

| File | Unused Import |
|------|--------------|
| `metrics.zig` | `Ulid` |
| `renderer.zig` | `Allocator` |
| `file_watcher.zig` | `Ulid` |
| `main.zig` | `agx` |
| `init.zig` | `agx` (only used for `GitCli`) |

### 25. `agx_dir` allocated but unused in init.zig

**File:** `src/cli/init.zig:25-26` — allocates `"{git_dir}/agx"` string, immediately defers free, never references it.

### 26. `decision_log.md` repeats headers per event

**File:** `src/storage/export.zig:267`

Prints `## Exploration [N]` for every decision event individually. Five decisions in one exploration produce five identical section headers.

### 27. `writeSummary` accepts unused `store` parameter

**File:** `src/storage/export.zig:75`

```zig
_ = store;
```

### 28. `error_count` type inconsistency

**File:** `src/compare/metrics.zig`

`error_count` is `i64` while all other counters are `u32`. The store's `countErrorsByExploration` returns `i64` from SQLite, but it should be cast to `u32` for consistency.

### 29. Missing `format` function on `Ulid`

`Ulid` has no `pub fn format(...)` for use with `std.fmt`. Adding one would make ULIDs directly printable in format strings, which would simplify debug logging.

---

## Architecture Recommendations

### Use arena allocators for query results

The biggest source of complexity is the manual free-every-field pattern. An arena allocator per command invocation would eliminate all of it:

```zig
var arena = std.heap.ArenaAllocator.init(alloc);
defer arena.deinit(); // frees everything at once
const a = arena.allocator();

var store = try agx.Store.init(a, db_path);
const task = try store.getActiveTask(); // all duped into arena
// no individual frees needed
```

This would require the `Store` to accept the allocator per-query (or store an arena reference), but would eliminate the entire class of partial-free bugs.

### Cache prepared statements

Every `Store` method calls `prepare` + `defer finalize` on each invocation. For hot paths like `insertEvent` (called per-event during ingestion), caching prepared statements on the `Store` struct would significantly reduce overhead.

### Consider using `std.json` for serialization

The codebase has three separate places that manually construct JSON (renderer, export, log CLI). Using `std.json.stringify` or a streaming JSON writer would handle escaping correctly and reduce surface area for bugs.

---

## What's Done Well

- **Consistent module structure**: Every CLI command follows the same `run(alloc, args, stdout, stderr)` signature. Core entities are cleanly separated.
- **Correct Zig 0.15 patterns**: BufferedWriter/interface pattern, ArrayList unmanaged API, `errdefer` usage in `session_util.zig`, proper `@cImport` for SQLite.
- **SQL injection prevention**: All queries use parameterized bindings — no string interpolation in SQL.
- **Build system**: Clean vendored SQLite with appropriate compile flags (WAL mode, FTS5, JSON1, DQS=0). Proper module separation between `sqlite`, `agx`, and the main executable.
- **ULID implementation**: Elegant use of `u128` for bit manipulation, correct Crockford Base32 with ambiguity handling, fully stack-based with no allocations.
- **Test infrastructure**: `refAllDecls` in the root module ensures all submodule tests are discovered. Store tests use `:memory:` databases.
- **Git integration safety**: Uses `std.process.Child` (direct exec, no shell interpolation) for all git operations.
