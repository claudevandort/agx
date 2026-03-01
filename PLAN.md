# agx — Agent-Aware Version Control

## Context

Git tracks file snapshots but has no concept of agent sessions, parallel exploration, or the reasoning behind changes. When developers run multiple coding agents on the same task, they end up juggling worktrees and branches manually with no structured way to compare results or preserve context. agx layers agent-aware workflows on top of git, starting with the most concrete use case: parallel exploration.

## Data Model

```
Dispatch (1) ──< Goal (1) ──< Task (1) ──< Session (1) ──< Event
                                                │
                                                ├──< Snapshot
                                                └──< Evidence
```

- **Dispatch** — a group of independent goals to be worked in parallel and merged sequentially (description, base_commit, base_branch, status, merge_policy, merge_order)
- **Goal** — a unit of work (description, base_commit, base_branch, status, resolved_task_id, dispatch_id?)
- **Task** — one agent's attempt at a goal (worktree_path, branch_name, index, status, approach)
  - `approach` — strategic description set early (e.g., "middleware extraction" vs "service split"), distinct from `done --summary` which captures the outcome. Shown in `agx exploration status` and `agx exploration compare` even before the task is finished.
- **Session** — agent working context within a task (agent_type, model_version, environment_fingerprint, initial_prompt, timestamps, exit_reason)
- **Event** — individual action in a session (kind: message, tool_call, decision, file_change, git_commit, error, custom)
- **Snapshot** — periodic worktree state capture (commit_sha, summary)
- **Evidence** — discrete test/build/analysis artifact tied to a task (kind, status, hash, summary)

IDs are ULIDs (time-sortable, globally unique).

### Evidence

Evidence captures structured results from tests, builds, and analysis tools — as distinct artifacts rather than parsed-from-events. Each evidence record includes:

- `kind` — test_result, build_output, coverage_report, lint_result, benchmark, custom
- `status` — pass, fail, error, skip
- `hash` — content hash of the raw output (for deduplication and integrity)
- `summary` — one-line human-readable result (e.g., "47/47 tests passed", "build failed: missing import")
- `raw_path` — optional path to full output file in `.git/agx/evidence/{task_id}/`
- `recorded_at` — timestamp

Evidence makes `agx exploration compare` more reliable than parsing events, and provides the foundation for future policy enforcement (e.g., "all tasks must have passing tests before `agx exploration pick`").

### Session Metadata

Sessions capture enough context to understand *how* a task was produced:

- `agent_type` — e.g., "claude-code", "copilot", "aider", "custom"
- `model_version` — e.g., "claude-sonnet-4-20250514", "gpt-4o-2024-08-06"
- `environment_fingerprint` — toolchain/runtime versions, OS, relevant env vars
- `initial_prompt` — the goal/instruction given to the agent at session start
- `timestamps` — start, end
- `exit_reason` — completed, interrupted, error, timeout

When comparing tasks, knowing that task 1 used Sonnet and task 2 used Opus matters for interpreting results.

## Storage Layout

```
.git/agx/                        # Local, not tracked by git
  db.sqlite3                     # Primary store (SQLite WAL mode)
  config.toml                    # Local config
  cache/                         # Comparison result cache
  evidence/{task_id}/            # Raw evidence outputs (test logs, coverage, etc.)
  worktrees/{goal_short}/{idx}/  # Agent worktrees

.agx/                            # Tracked by git (opt-in, for team sharing)
  config.toml                    # Shared config
  context/{goal_id}/             # Preserved context from resolved goals
    summary.md
    sessions.jsonl
    evidence.json                # Evidence manifest
    decision_log.md
```

SQLite for the hot path (thousands of events per session, concurrent writes). JSONL for exported context (human-readable, git-diffable).

## Git Integration

- **Branches**: `agx/{goal_id_short}/{task_index}` (e.g., `agx/01JK7M/2`) for tasks, `agx/dispatch-{dispatch_short}/{goal_index}` for dispatch goals
- **Worktrees**: `.git/agx/worktrees/{goal_id_short}/{idx}/` for tasks, `.git/agx/worktrees/dispatch-{dispatch_short}/{idx}/` for dispatch goals
- **Implementation**: Shell out to `git` via `std.process.Child` (worktree ops don't have clean libgit2 equivalents; preserves user's git config/hooks). Wrap in a `GitCli` abstraction for future swap to libgit2.
- **Merge strategies**: merge (default), rebase, squash, cherry-pick

### Commit Trailers

When `agx exploration pick` merges a task into the base branch, stamp every merged commit with trailers via `git interpret-trailers`:

```
AGX-Goal: 01JK7M
AGX-Task: 2
AGX-Agent: claude-code
AGX-Model: claude-sonnet-4-20250514
```

Dispatch merges add `AGX-Dispatch` and `AGX-Goal` trailers to each merge commit.

Trailers are the lightest possible way to preserve provenance in permanent git history. They survive rebases, work with every forge, show up in `git log`, and cost nothing. After agx metadata is cleaned up, the trailers remain as a permanent audit trail of which agent produced which code.

## CLI Commands — Parallel Exploration Workflow

```bash
# Initialize
agx init                              # set up .git/agx/
agx init --shared                     # also create .agx/ for team sharing

# Spawn N tasks
agx exploration create --goal "refactor auth" --count 3
agx exploration create --goal "refactor auth" --count 3 --base main~2
agx exploration create --goal "refactor auth" --count 3 --approach "middleware" "service-split" "decorator"

# Set or update approach description
agx exploration approach "Extracting auth into middleware chain"

# Monitor
agx exploration status                # all active goals
agx exploration status --goal <id>    # one goal detail
agx exploration log <index>           # stream events for task N

# Record evidence
agx exploration evidence --kind test_result --status pass --summary "47/47 tests passed"
agx exploration evidence --kind build_output --status fail --summary "missing import" --file build.log

# Complete a task (run from within worktree)
agx exploration done
agx exploration done --summary "Extracted auth into middleware chain"

# Compare results
agx exploration compare               # table comparing all tasks
agx exploration compare --diff 1 2    # three-way diff between tasks
agx exploration compare --format json # machine-readable output

# Keep the best
agx exploration pick 2                # merge task 2 into base branch
agx exploration pick 2 --strategy squash
agx exploration pick 2 --preserve-context    # export session logs to .agx/context/
agx exploration pick 2 --no-cleanup          # keep worktrees around

# Archive (preserve context from tasks you didn't pick)
agx exploration archive 1             # export context, then remove worktree
agx exploration archive --all         # archive all non-kept tasks

# Cleanup
agx exploration discard 1             # remove one task (no context preserved)
agx exploration clean                 # remove all resolved goal artifacts
```

## CLI Commands — Dispatch Workflow

```bash
# Create a dispatch of independent goals
agx dispatch create --goals "add auth" "add logging" "refactor config" --policy semi
agx dispatch create --goals "goal A" "goal B" --policy autonomous --base main~2

# Monitor dispatch progress
agx dispatch status                   # dispatch info + per-goal table
agx dispatch status --dispatch <id>   # specific dispatch

# Preview merge order and file overlap
agx dispatch merge --dry-run

# Execute sequential merge (least-conflict-first ordering)
agx dispatch merge
```

### Merge policies

- **`autonomous`** — the lead agent resolves all merge conflicts
- **`semi`** — lead resolves trivial conflicts, asks user for complex ones
- **`manual`** — every conflict goes to the user

### `agx exploration create` vs `agx dispatch create`

`agx exploration create` creates N tasks for **the same goal** (competing approaches) — you pick one winner with `agx exploration pick`.

`agx dispatch create` creates N **different goals** (independent work) — all get merged together sequentially with conflict-aware ordering.

### `agx exploration archive` vs `agx exploration discard`

`agx exploration archive` exports a task's session logs, evidence, and decision history to `.agx/context/` before removing the worktree — preserving the reasoning and results from tasks you didn't pick. The task branch remains in git as an orphan ref. This supports the principle that abandoned explorations are valuable context, not garbage.

`agx exploration discard` removes the worktree and branch with no context preservation. Use when a task is clearly junk (e.g., went completely off track).

## Comparison Engine (`agx exploration compare`)

Per-task metrics relative to base_commit:

| Metric | Source |
|--------|--------|
| Files changed/created/deleted | `git diff --numstat`, `--diff-filter` |
| Lines added/removed | `git diff --numstat` |
| Commit count | `git rev-list --count` |
| Test results | Evidence records (kind=test_result) |
| Build success | Evidence records (kind=build_output) |
| Approach | Task `approach` field |
| Outcome summary | `done --summary` |
| Agent / model | Session metadata |
| Time elapsed | Session timestamps |
| Error count | Event query |

Output includes a file overlap matrix showing which tasks touched which files.

## Agent Integration

Three tiers (agents pick what works for them):

1. **File-based** (zero integration): agent appends JSONL to `.git/agx/events/{session_id}.jsonl`, agx tails and ingests
2. **CLI-based**: `agx record event --kind tool_call --data '{...}'`
3. **Socket-based** (lowest latency, future): Unix domain socket at `/tmp/agx-{pid}.sock`, JSONL protocol, batched SQLite inserts. To be added when low-latency ingestion is needed.

Discovery via `.agx-session` file written in each worktree root (contains session_id, socket path, etc.).

## Project Structure (Zig)

```
agx/
  build.zig                      # Compiles vendored SQLite, builds agx binary
  build.zig.zon
  src/
    main.zig                     # Entry point, CLI dispatch
    cli/                         # One file per command (exploration.zig, dispatch.zig, spawn.zig, compare.zig, keep.zig, ...)
    core/                        # Entities (goal.zig, task.zig, session.zig, event.zig, evidence.zig, dispatch.zig, ulid.zig)
    dispatch/                    # Dispatch-specific logic (overlap.zig — file overlap analysis + merge ordering)
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
4. **cli/init.zig + cli/spawn.zig** — create worktrees and goal records
5. **cli/status.zig + cli/done.zig** — monitor and complete tasks
6. **cli/approach.zig + cli/evidence.zig** — set approach, record evidence
7. **compare/ engine + cli/compare.zig** — the flagship feature
8. **cli/keep.zig + cli/archive.zig + cli/discard.zig + cli/clean.zig** — resolution and cleanup
9. **daemon/ + agent integration** — event ingestion (file-based first, then socket)
10. **cli/record.zig + cli/log.zig** — event recording and viewing
11. **export to .agx/context/** — context preservation
11b. **dispatch/ + cli/dispatch.zig** — multi-goal dispatch execution with conflict-aware merging (Dispatch entity, overlap analysis, sequential merge)

## Verification

- **Unit tests**: each module in `test/unit/`
- **Integration tests**: `test/integration/full_workflow_test.zig` — spawn 3 tasks in a temp git repo, simulate file changes in each worktree, run compare, keep one, archive the rest, verify merge, trailers, and cleanup
- **Manual smoke test**: `agx init && agx exploration create --goal "test" --count 2`, make changes in each worktree, `agx exploration done` in each, `agx exploration compare`, `agx exploration pick 1`, verify commit trailers in `git log`

## Next: Agent Orchestration (Steps 12–16)

### 12. Claude Code skill-based integration (manual orchestration)

Test agx with real agents using Claude Code skills — no agx code changes needed:

- **`agx-explore-lead` skill** — for the team lead agent (parallel explorations). Instructions on how to:
  - `agx init` and `agx exploration create` to set up parallel tasks
  - Launch teammates in the spawned worktrees
  - Monitor with `agx exploration status` and `agx exploration compare`
  - Pick the winner with `agx exploration pick`, clean up with `agx exploration archive`/`agx exploration discard`/`agx exploration clean`

- **`agx-explore-teammate` skill** — for each teammate agent working in a worktree. Instructions on how to:
  - Read `.agx-session` to discover session/task context
  - `agx exploration approach "..."` to declare strategy early
  - `agx exploration evidence` to record test/build results
  - `agx exploration done --summary "..."` when finished

- **`agx-dispatch-lead` skill** — for the team lead agent (multi-goal dispatch). Instructions on how to:
  - `agx dispatch create` to create a dispatch of independent goals with worktrees
  - Launch teammates (one per goal) using the `agx-explore-teammate` skill
  - Monitor with `agx dispatch status`
  - `agx dispatch merge --dry-run` to preview merge order and file overlap
  - `agx dispatch merge` to execute sequential merge with conflict-aware ordering
  - Handle conflicts per merge policy (autonomous/manual)

### 13. Orchestrator command (`agx exploration create --run`)

Extend `agx exploration create` to optionally launch a command in each worktree:

```bash
agx exploration create --goal "fix auth" --count 3 --run "claude -p 'fix the auth bug'"
```

- Fork a child process per worktree with cwd set to the worktree path
- Track PIDs in the session record
- On process exit: auto-mark task `done`, capture exit code

### 14. Auto-evidence collection (`--verify`)

Run a verification command after each agent exits:

```bash
agx exploration create --goal "fix auth" --count 3 --run "claude -p '...'" --verify "npm test"
```

- Execute verify command in each worktree after the agent process exits
- Parse exit code → `pass`/`fail`, capture stdout as evidence summary
- Record as `agx exploration evidence --kind test_result --status pass/fail`

### 15. Auto-done detection

When the orchestrator is not used (agents launched manually):
- `agx ingest --watch` detects stale tasks (no new events for N minutes) and marks them done
- Or a new `agx watch` command that monitors worktree git activity

### 16. Policy enforcement on `agx exploration pick`

```bash
agx exploration pick 2 --require-evidence          # must have at least one evidence record
agx exploration pick 2 --require-tests-pass        # must have passing test_result evidence
```

Fail with a clear error if the task doesn't meet the policy. `--force` to override.

## Future Extensibility

The architecture naturally extends to:
- **Context preservation**: `agx exploration pick --preserve-context` already designed; future `agx context search` for RAG over archived explorations
- **Concurrent editing**: same worktree infra, add conflict detection before merge
- **Session management**: pause/resume/transfer via Session entity
- **Plugin system**: custom event kinds + JSONL protocol = easy third-party integration
- **Remote sync**: push/pull SQLite exports for team visibility
- **Server-side policy engine**: enforce rules on agent pushes via git hooks (`pre-receive`, `update`, `post-receive`). Examples: require passing evidence before `agx exploration pick`, restrict which agents can push to which branches, validate evidence manifest hashes, require commit trailers on agent-authored commits. The local Evidence + Session metadata model is designed to support this — a server-side policy layer would query the same schemas. Start with local enforcement (`agx exploration pick --require-evidence`), graduate to server hooks when team workflows demand it.
