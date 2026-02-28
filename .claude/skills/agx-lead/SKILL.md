---
name: agx-lead
description: Use when orchestrating parallel agent explorations with agx. Handles spawning tasks, launching teammates in worktrees, monitoring progress, comparing results, and merging the best exploration.
---

# agx Lead

You are the lead agent coordinating parallel explorations using `agx`. You use Claude Code agent teams to launch teammates, each working in an isolated git worktree.

## 1. Setup

Initialize agx and spawn explorations:

```bash
agx init
agx spawn --task "description of the task" --count N
```

Then check what was created:
```bash
agx status
```

Each exploration has an index `[1]`, `[2]`, etc. and a worktree path.

## 2. Create a team and launch teammates

Use `TeamCreate` to create a team, then spawn one teammate per exploration using the `Task` tool with `team_name`.

For each teammate:
- Use `subagent_type: "general-purpose"` (they need to edit files)
- Include `/agx-teammate` in their prompt so they know how to use agx
- Tell them the task description, their exploration index, and worktree path

Example teammate prompt:
```
Your working directory is <worktree_path>.
You are agx exploration [1]. Your task: "<task description>".
Invoke /agx-teammate then work on the task.
```

Launch all teammates in parallel (multiple Task tool calls in one message). Run them in the background so you can monitor progress.

## 3. Monitor

While teammates work:
```bash
agx status                    # overview of all explorations
agx log <index>               # event history for one exploration
agx log <index> --kind error  # just errors
```

Wait for all explorations to reach `done` status.

## 4. Compare and decide

```bash
agx compare                   # side-by-side comparison table
agx compare --format json     # machine-readable
```

The comparison shows: files changed, lines added/removed, commit count, test pass/fail, build status, error count, approach, and summary. Use this to pick the best exploration.

After deciding, record your reasoning so the decision log captures *why* you chose the winner:
```bash
agx record --kind decision "Keeping [2]: cleaner separation of concerns, all tests pass, fewer lines changed. [1] worked but coupled auth to routing. [3] had failing tests."
```

This is especially valuable when context is preserved — future agents can see not just what was tried but why one approach won.

## 5. Merge the winner

```bash
agx keep <index>                        # merge and export context
agx keep <index> --strategy squash      # squash merge
agx keep <index> --no-context           # skip context export
```

Context (decision log, evidence, session history) is exported to `.agx/context/` by default. Only use `--no-context` for trivial tasks where the history isn't worth keeping.

## 6. Cleanup

```bash
agx archive <index>    # preserve context, remove worktree (for useful explorations you didn't pick)
agx discard <index>    # remove worktree, no context (for junk explorations)
agx clean              # remove all resolved task artifacts
```

Then shut down teammates and delete the team.

## Important

- Always wait for all teammates to finish before comparing.
- Run `agx compare` before deciding which to keep.
- Use `agx archive` (not `discard`) for explorations with useful insights.
- `agx keep` exports context by default — use `--no-context` to skip.
