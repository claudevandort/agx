# agx — Agent-Aware Version Control

`agx` layers agent-aware workflows on top of git. It supports two modes:

- **explore** (multiple agents tackle the same goal with competing approaches — compare and keep the best)
-  **dispatch** (multiple independent goals run in parallel — merge them all back sequentially with conflict-aware ordering).

In both modes, `agx` gives each agent an isolated worktree, tracks sessions and evidence, and merges results back with full provenance.

## Install

Requires [Zig 0.15.2](https://ziglang.org/download/).

```bash
git clone <repo-url>
cd agx
zig build
# Binary is at zig-out/bin/agx
```

## Quick Start

```bash
# Initialize agx in an existing git repo
cd my-project
agx init

# Spawn 3 parallel tasks for a goal
agx exploration create --goal "refactor auth module" --count 3
```

This creates 3 git worktrees, each with its own branch, session, and a `.agx-session` discovery file. Agents (or humans) can now work independently in each worktree.

## Explore Workflow

One goal, N competing approaches. Compare results, keep the best.

### Inside each worktree (agent or human)

```bash
# Declare the approach being taken
agx exploration approach "Extract auth into middleware chain"

# Record evidence as you go
agx exploration evidence --kind test_result --status pass --summary "47/47 tests passed"
agx exploration evidence --kind build_output --status pass --summary "clean build"

# Record events (for detailed audit trail)
agx record event --kind tool_call --data '{"tool":"grep","args":"auth"}'

# Mark the task complete
agx exploration done --summary "Refactored auth into express middleware"
```

### From the main repo (comparing and deciding)

```bash
# See the state of all tasks
agx exploration status

# Compare tasks side by side
agx exploration compare

# Example output:
#  Idx  Status   Files  +Lines  -Lines  Commits  Tests✓  Tests✗  Build  Errors
#  [1]  done        4      87      23        3       47       0    ✓       0
#  [2]  done        7     142      58        5       47       0    ✓       2
#  [3]  active      2      31       8        1        -       -    -       0

# Machine-readable output
agx exploration compare --format json

# View event log for a specific task
agx exploration log 2
agx exploration log 2 --kind error --json

# Merge the best task back to your branch
agx exploration pick 1
agx exploration pick 1 --strategy squash          # squash merge
agx exploration pick 1 --preserve-context         # export session logs to .agx/context/

# Clean up
agx exploration archive 3          # preserve context, remove worktree
agx exploration discard 2          # remove worktree, no context preserved
agx exploration clean              # remove all resolved goal artifacts
```

### Merge strategies

`agx exploration pick` supports `--strategy merge` (default), `rebase`, `squash`, and `cherry-pick`.

Merged commits are stamped with git trailers for provenance:

```
AGX-Goal: 01JK7M
AGX-Task: 1
AGX-Agent: claude-code
AGX-Model: claude-sonnet-4-20250514
```

### Searching archived context

After using `--preserve-context`, the exported context is searchable:

```bash
agx context list                       # list all archived goals
agx context list --status resolved     # filter by status
agx context search "auth middleware"   # search across all context files
agx context search "test" --goal 01JK  # search within a specific goal
```

Context files in `.agx/context/` are tracked by git, so the full exploration history is available to anyone who clones the repo — even without `agx init`.

## Dispatch Workflow

N independent goals, worked in parallel, merged sequentially with least-conflict-first ordering.

```bash
# Create a dispatch of goals
agx dispatch create --goals "add auth middleware" "add request logging" "refactor config" --policy autonomous

# Each goal gets its own worktree and branch
# Dispatch 01KJJ2: Dispatch of 3 goals
#   [1] 01KJJ2 — add auth middleware        worktree: .git/agx/worktrees/dispatch-01KJJ2/1
#   [2] 01KJJ2 — add request logging        worktree: .git/agx/worktrees/dispatch-01KJJ2/2
#   [3] 01KJJ2 — refactor config            worktree: .git/agx/worktrees/dispatch-01KJJ2/3
```

Agents work in each worktree independently. When all goals are done:

```bash
# Check dispatch status
agx dispatch status

# Preview merge order and file overlap
agx dispatch merge --dry-run

# Example dry-run output:
# Merge order (3 goals):
#   1. [3] refactor config (2 files changed)
#   2. [1] add auth middleware (4 files changed)
#   3. [2] add request logging (3 files changed)
#
# File overlap:
#   [1] <-> [2]: 1 shared file(s)

# Execute the merge
agx dispatch merge

# If a merge has conflicts, resolve them and continue
git add <resolved files>
agx dispatch merge --continue

# Cancel an active dispatch (aborts in-progress merges)
agx dispatch cancel
```

agx computes which goals share the most files and merges the least-overlapping goals first to minimize conflicts. Each goal is squash-merged with `AGX-Dispatch` and `AGX-Goal` trailers.

When a merge step has conflicts, the dispatch pauses with `conflict` status. After resolving conflicts and staging files, run `agx dispatch merge --continue` to commit the resolution and continue merging remaining goals.

### Conflict policies

Set with `--policy` during `dispatch create`:

- `autonomous` — the agent resolves all merge conflicts
- `semi` — the agent resolves trivial conflicts, asks the user for complex ones
- `manual` — every conflict goes to the user

## Agent Integration

Agents can integrate at two levels:

**CLI-based** — call agx commands directly:
```bash
agx record event --kind tool_call --data '{"tool":"edit","file":"auth.py"}'
agx exploration evidence --kind test_result --status pass --summary "all tests pass"
agx exploration done --summary "completed refactoring"
```

**File-based** — append JSONL to the events directory (zero integration required):
```bash
# Agents write to .git/agx/events/{session_id}.jsonl
echo '{"kind":"tool_call","data":"{\"tool\":\"grep\"}","timestamp":1700000000000}' >> .git/agx/events/$SESSION_ID.jsonl

# agx ingests the events
agx ingest              # one-shot
agx ingest --watch      # continuous polling
```

**Session discovery** — each worktree contains `.agx-session`:
```
session_id=01JKAB3F...
task_id=01JKAB3G...
goal_id=01JKAB3E...
index=1
```

## Data Model

```
Dispatch (optional) ──< Goal (1) ──< Task (1) ──< Session (1) ──< Event
                                                       │
                                                       ├──< Snapshot
                                                       └──< Evidence
```

- **Dispatch** — a group of independent goals to be merged sequentially (merge policy, merge order, base commit)
- **Goal** — a unit of work with a base commit/branch (optionally belongs to a dispatch)
- **Task** — one agent's attempt (own worktree + branch)
- **Session** — agent working context (agent type, model version, timing)
- **Event** — individual action (message, tool_call, decision, file_change, git_commit, error)
- **Evidence** — structured test/build result (kind, status, summary, optional raw output)
- **Snapshot** — periodic worktree state capture

IDs are ULIDs (time-sortable, globally unique).

## Storage

```
.git/agx/                          # Local, not tracked by git
  db.sqlite3                       # SQLite database (WAL mode)
  events/{session_id}.jsonl        # Agent event files (for ingestion)
  evidence/{task_id}/              # Raw evidence outputs

.agx/                              # Tracked by git (for team sharing)
  context/{goal_id}/               # Preserved context from resolved goals
    summary.md
    sessions.jsonl
    evidence.json
    decision_log.md
```

## Commands

| Command | Description |
|---------|-------------|
| `agx init` | Initialize agx in a git repository |
| `agx exploration create` | Create parallel tasks with worktrees |
| `agx exploration status` | Show goal and task status |
| `agx exploration approach` | Set strategic approach for current task |
| `agx exploration evidence` | Record structured test/build evidence |
| `agx exploration done` | Mark current task as complete |
| `agx exploration compare` | Compare tasks side by side |
| `agx exploration log` | View event history for a task |
| `agx exploration pick` | Merge a task back to the base branch |
| `agx exploration archive` | Preserve context and remove worktree |
| `agx exploration discard` | Remove worktree without preserving context |
| `agx exploration clean` | Remove all artifacts from resolved goals |
| `agx record` | Record events to the session log |
| `agx context` | List and search archived task context |
| `agx ingest` | Ingest agent events from JSONL files |
| `agx dispatch create` | Create a dispatch of independent goals with worktrees |
| `agx dispatch status` | Show dispatch and per-goal status |
| `agx dispatch merge` | Merge all completed goals sequentially (`--dry-run`, `--continue`) |
| `agx dispatch cancel` | Cancel an active dispatch and abort in-progress merges |

## Building & Testing

```bash
zig build              # build the binary
zig build test         # run all tests
zig build run -- help  # run with arguments
```

No external dependencies. SQLite 3.47.2 is vendored and compiled from source.
