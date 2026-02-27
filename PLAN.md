# agx — Agent-Aware Version Control

## Context

Git tracks file snapshots but has no concept of agent sessions, parallel exploration, or the reasoning behind changes. When developers run multiple coding agents on the same task, they end up juggling worktrees and branches manually with no structured way to compare results or preserve context. agx layers agent-aware workflows on top of git, starting with the most concrete use case: parallel exploration.

## Data Model

```
Task (1) ──< Exploration (1) ──< Session (1) ──< Event
                                     │
                                     ├──< Snapshot
                                     └──< Evidence
```

- **Task** — a unit of work (description, base_commit, base_branch, status, resolved_session)
- **Exploration** — one agent's attempt at a task (worktree_path, branch_name, index, status, approach)
  - `approach` — strategic description set early (e.g., "middleware extraction" vs "service split"), distinct from `done --summary` which captures the outcome. Shown in `agx status` and `agx compare` even before the exploration is finished.
- **Session** — agent working context within an exploration (agent_type, model_version, environment_fingerprint, initial_prompt, timestamps, exit_reason)
- **Event** — individual action in a session (kind: message, tool_call, decision, file_change, git_commit, error, custom)
- **Snapshot** — periodic worktree state capture (commit_sha, summary)
- **Evidence** — discrete test/build/analysis artifact tied to an exploration (kind, status, hash, summary)

IDs are ULIDs (time-sortable, globally unique).

### Evidence

Evidence captures structured results from tests, builds, and analysis tools — as distinct artifacts rather than parsed-from-events. Each evidence record includes:

- `kind` — test_result, build_output, coverage_report, lint_result, benchmark, custom
- `status` — pass, fail, error, skip
- `hash` — content hash of the raw output (for deduplication and integrity)
- `summary` — one-line human-readable result (e.g., "47/47 tests passed", "build failed: missing import")
- `raw_path` — optional path to full output file in `.git/agx/evidence/{exploration_id}/`
- `recorded_at` — timestamp

Evidence makes `agx compare` more reliable than parsing events, and provides the foundation for future policy enforcement (e.g., "all explorations must have passing tests before `agx keep`").

### Session Metadata

Sessions capture enough context to understand *how* an exploration was produced:

- `agent_type` — e.g., "claude-code", "copilot", "aider", "custom"
- `model_version` — e.g., "claude-sonnet-4-20250514", "gpt-4o-2024-08-06"
- `environment_fingerprint` — toolchain/runtime versions, OS, relevant env vars
- `initial_prompt` — the goal/instruction given to the agent at session start
- `timestamps` — start, end
- `exit_reason` — completed, interrupted, error, timeout

When comparing explorations, knowing that exploration 1 used Sonnet and exploration 2 used Opus matters for interpreting results.

## Storage Layout

```
.git/agx/                        # Local, not tracked by git
  db.sqlite3                     # Primary store (SQLite WAL mode)
  config.toml                    # Local config
  cache/                         # Comparison result cache
  evidence/{exploration_id}/     # Raw evidence outputs (test logs, coverage, etc.)
  worktrees/{task_short}/{idx}/  # Agent worktrees

.agx/                            # Tracked by git (opt-in, for team sharing)
  config.toml                    # Shared config
  context/{task_id}/             # Preserved context from resolved tasks
    summary.md
    sessions.jsonl
    evidence.json                # Evidence manifest
    decision_log.md
```

SQLite for the hot path (thousands of events per session, concurrent writes). JSONL for exported context (human-readable, git-diffable).

## Git Integration

- **Branches**: `agx/{task_id_short}/{exploration_index}` (e.g., `agx/01JK7M/2`)
- **Worktrees**: `.git/agx/worktrees/{task_id_short}/{idx}/`
- **Implementation**: Shell out to `git` via `std.process.Child` (worktree ops don't have clean libgit2 equivalents; preserves user's git config/hooks). Wrap in a `GitCli` abstraction for future swap to libgit2.
- **Merge strategies**: merge (default), rebase, squash, cherry-pick

### Commit Trailers

When `agx keep` merges an exploration into the base branch, stamp every merged commit with trailers via `git interpret-trailers`:

```
AGX-Task: 01JK7M
AGX-Exploration: 2
AGX-Agent: claude-code
AGX-Model: claude-sonnet-4-20250514
```

Trailers are the lightest possible way to preserve provenance in permanent git history. They survive rebases, work with every forge, show up in `git log`, and cost nothing. After agx metadata is cleaned up, the trailers remain as a permanent audit trail of which agent produced which code.

## CLI Commands — Parallel Exploration Workflow

```bash
# Initialize
agx init                              # set up .git/agx/
agx init --shared                     # also create .agx/ for team sharing

# Spawn N explorations
agx spawn --task "refactor auth" --count 3
agx spawn --task "refactor auth" --count 3 --base main~2
agx spawn --task "refactor auth" --count 3 --approach "middleware" "service-split" "decorator"

# Set or update approach description
agx approach "Extracting auth into middleware chain"

# Monitor
agx status                            # all active tasks
agx status --task <id>                # one task detail
agx log <index>                       # stream events for exploration N

# Record evidence
agx evidence --kind test_result --status pass --summary "47/47 tests passed"
agx evidence --kind build_output --status fail --summary "missing import" --file build.log

# Complete an exploration (run from within worktree)
agx done
agx done --summary "Extracted auth into middleware chain"

# Compare results
agx compare                           # table comparing all explorations
agx compare --diff 1 2                # three-way diff between explorations
agx compare --format json             # machine-readable output

# Keep the best
agx keep 2                            # merge exploration 2 into base branch
agx keep 2 --strategy squash
agx keep 2 --preserve-context         # export session logs to .agx/context/
agx keep 2 --no-cleanup               # keep worktrees around

# Archive (preserve context from explorations you didn't pick)
agx archive 1                         # export context, then remove worktree
agx archive --all                     # archive all non-kept explorations

# Cleanup
agx discard 1                         # remove one exploration (no context preserved)
agx clean                             # remove all resolved task artifacts
```

### `agx archive` vs `agx discard`

`agx archive` exports an exploration's session logs, evidence, and decision history to `.agx/context/` before removing the worktree — preserving the reasoning and results from explorations you didn't pick. The exploration branch remains in git as an orphan ref. This supports the principle that abandoned explorations are valuable context, not garbage.

`agx discard` removes the worktree and branch with no context preservation. Use when an exploration is clearly junk (e.g., went completely off track).

## Comparison Engine (`agx compare`)

Per-exploration metrics relative to base_commit:

| Metric | Source |
|--------|--------|
| Files changed/created/deleted | `git diff --numstat`, `--diff-filter` |
| Lines added/removed | `git diff --numstat` |
| Commit count | `git rev-list --count` |
| Test results | Evidence records (kind=test_result) |
| Build success | Evidence records (kind=build_output) |
| Approach | Exploration `approach` field |
| Outcome summary | `done --summary` |
| Agent / model | Session metadata |
| Time elapsed | Session timestamps |
| Error count | Event query |

Output includes a file overlap matrix showing which explorations touched which files.

## Agent Integration

Three tiers (agents pick what works for them):

1. **File-based** (zero integration): agent appends JSONL to `.git/agx/events/{session_id}.jsonl`, agx tails and ingests
2. **CLI-based**: `agx record event --kind tool_call --data '{...}'`
3. **Socket-based** (lowest latency): Unix domain socket at `/tmp/agx-{pid}.sock`, JSONL protocol, batched SQLite inserts

Discovery via `.agx-session` file written in each worktree root (contains session_id, socket path, etc.).

## Project Structure (Zig)

```
agx/
  build.zig                      # Compiles vendored SQLite, builds agx binary
  build.zig.zon
  src/
    main.zig                     # Entry point, CLI dispatch
    cli/                         # One file per command (spawn.zig, compare.zig, keep.zig, ...)
    core/                        # Entities (task.zig, exploration.zig, session.zig, event.zig, evidence.zig, ulid.zig)
    storage/                     # sqlite.zig, migrations.zig, export.zig
    git/                         # cli_backend.zig, worktree.zig, diff.zig, branch.zig, trailers.zig
    compare/                     # metrics.zig, diff_analyzer.zig, renderer.zig
    daemon/                      # socket_server.zig, file_watcher.zig, batcher.zig
    util/                        # toml.zig, json.zig, time.zig, format.zig
  deps/sqlite/                   # Vendored SQLite amalgamation
  test/
    integration/                 # Full workflow tests
    unit/                        # Per-module tests
```

## Implementation Order

1. **build.zig + deps/sqlite** — get SQLite compiling from vendored source
2. **core/ entities + storage/sqlite.zig** — data model and persistence (including Evidence entity)
3. **git/cli_backend.zig** — git abstraction (worktree, diff, branch, merge, trailers)
4. **cli/init.zig + cli/spawn.zig** — create worktrees and task records
5. **cli/status.zig + cli/done.zig** — monitor and complete explorations
6. **cli/approach.zig + cli/evidence.zig** — set approach, record evidence
7. **compare/ engine + cli/compare.zig** — the flagship feature
8. **cli/keep.zig + cli/archive.zig + cli/discard.zig + cli/clean.zig** — resolution and cleanup
9. **daemon/ + agent integration** — event ingestion (file-based first, then socket)
10. **cli/record.zig + cli/log.zig** — event recording and viewing
11. **export to .agx/context/** — context preservation

## Verification

- **Unit tests**: each module in `test/unit/`
- **Integration tests**: `test/integration/full_workflow_test.zig` — spawn 3 explorations in a temp git repo, simulate file changes in each worktree, run compare, keep one, archive the rest, verify merge, trailers, and cleanup
- **Manual smoke test**: `agx init && agx spawn --task "test" --count 2`, make changes in each worktree, `agx done` in each, `agx compare`, `agx keep 1`, verify commit trailers in `git log`

## Future Extensibility

The architecture naturally extends to:
- **Context preservation**: `agx keep --preserve-context` already designed; future `agx context search` for RAG over archived explorations
- **Concurrent editing**: same worktree infra, add conflict detection before merge
- **Session management**: pause/resume/transfer via Session entity
- **Plugin system**: custom event kinds + JSONL protocol = easy third-party integration
- **Remote sync**: push/pull SQLite exports for team visibility
- **Server-side policy engine**: enforce rules on agent pushes via git hooks (`pre-receive`, `update`, `post-receive`). Examples: require passing evidence before `agx keep`, restrict which agents can push to which branches, validate evidence manifest hashes, require commit trailers on agent-authored commits. The local Evidence + Session metadata model is designed to support this — a server-side policy layer would query the same schemas. Start with local enforcement (`agx keep --require-evidence`), graduate to server hooks when team workflows demand it.
