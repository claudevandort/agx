# agx — Agent-Aware Version Control

agx layers agent-aware workflows on top of git. When you run multiple AI coding agents on the same task, agx gives each one an isolated worktree, tracks their sessions and evidence, lets you compare results side by side, and merges the best exploration back to your branch with full provenance.

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

# Spawn 3 parallel explorations for a task
agx spawn --task "refactor auth module" --count 3
```

This creates 3 git worktrees, each with its own branch, session, and a `.agx-session` discovery file. Agents (or humans) can now work independently in each worktree.

## Workflow

### Inside each worktree (agent or human)

```bash
# Declare the approach being taken
agx approach "Extract auth into middleware chain"

# Record evidence as you go
agx evidence --kind test_result --status pass --summary "47/47 tests passed"
agx evidence --kind build_output --status pass --summary "clean build"

# Record events (for detailed audit trail)
agx record event --kind tool_call --data '{"tool":"grep","args":"auth"}'

# Mark the exploration complete
agx done --summary "Refactored auth into express middleware"
```

### From the main repo (comparing and deciding)

```bash
# See the state of all explorations
agx status

# Compare explorations side by side
agx compare

# Example output:
#  Idx  Status   Files  +Lines  -Lines  Commits  Tests✓  Tests✗  Build  Errors
#  [1]  done        4      87      23        3       47       0    ✓       0
#  [2]  done        7     142      58        5       47       0    ✓       2
#  [3]  active      2      31       8        1        -       -    -       0

# Machine-readable output
agx compare --format json

# View event log for a specific exploration
agx log 2
agx log 2 --kind error --json

# Merge the best exploration back to your branch
agx keep 1
agx keep 1 --strategy squash          # squash merge
agx keep 1 --preserve-context         # export session logs to .agx/context/

# Clean up
agx archive 3          # preserve context, remove worktree
agx discard 2          # remove worktree, no context preserved
agx clean              # remove all resolved task artifacts
```

### Merge strategies

`agx keep` supports `--strategy merge` (default), `rebase`, `squash`, and `cherry-pick`.

Merged commits are stamped with git trailers for provenance:

```
AGX-Task: 01JK7M
AGX-Exploration: 1
AGX-Agent: claude-code
AGX-Model: claude-sonnet-4-20250514
```

## Agent Integration

Agents can integrate at two levels:

**CLI-based** — call agx commands directly:
```bash
agx record event --kind tool_call --data '{"tool":"edit","file":"auth.py"}'
agx evidence --kind test_result --status pass --summary "all tests pass"
agx done --summary "completed refactoring"
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
exploration_id=01JKAB3G...
task_id=01JKAB3E...
index=1
```

## Data Model

```
Task (1) ──< Exploration (1) ──< Session (1) ──< Event
                                     │
                                     ├──< Snapshot
                                     └──< Evidence
```

- **Task** — a unit of work with a base commit/branch
- **Exploration** — one agent's attempt (own worktree + branch)
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
  evidence/{exploration_id}/       # Raw evidence outputs

.agx/                              # Tracked by git (for team sharing)
  context/{task_id}/               # Preserved context from resolved tasks
    summary.md
    sessions.jsonl
    evidence.json
    decision_log.md
```

## Commands

| Command | Description |
|---------|-------------|
| `agx init` | Initialize agx in a git repository |
| `agx spawn` | Create parallel explorations with worktrees |
| `agx status` | Show task and exploration status |
| `agx approach` | Set strategic approach for current exploration |
| `agx evidence` | Record structured test/build evidence |
| `agx record` | Record events to the session log |
| `agx done` | Mark current exploration as complete |
| `agx compare` | Compare explorations side by side |
| `agx log` | View event history for an exploration |
| `agx keep` | Merge an exploration back to the base branch |
| `agx archive` | Preserve context and remove worktree |
| `agx discard` | Remove worktree without preserving context |
| `agx clean` | Remove all artifacts from resolved tasks |
| `agx ingest` | Ingest agent events from JSONL files |

## Building & Testing

```bash
zig build              # build the binary
zig build test         # run all tests
zig build run -- help  # run with arguments
```

No external dependencies. SQLite 3.47.2 is vendored and compiled from source.
