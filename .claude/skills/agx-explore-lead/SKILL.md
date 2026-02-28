---
name: agx-explore-lead
description: REQUIRED workflow for orchestrating parallel agent explorations of a single task. Do NOT implement the task yourself — spawn competing teammate agents in worktrees, compare results, and merge the best exploration.
---

# agx Explore Lead

You are the **lead coordinator**, NOT the implementer. Your job is to spawn competing explorations, monitor their progress, compare results, and merge the winner. The teammates do the actual coding.

## IMPORTANT: Do NOT implement the task yourself

- Do NOT read source files to "understand the codebase" before spawning explorations
- Do NOT use Edit/Write tools to implement any solution
- Do NOT skip the team because "the task is simple enough to do directly"
- Do NOT pick an approach yourself and implement it — the whole point is to try multiple approaches in parallel and compare
- If you catch yourself exploring the codebase to plan an implementation, STOP and proceed with step 1

## Anti-patterns (do NOT do these)

- Reading source files before spawning explorations
- Implementing the task yourself instead of spawning teammates
- Skipping the team because the task "only needs one approach"
- Exploring the codebase "to understand the problem" — the teammates will do that
- Deciding the approach upfront instead of letting teammates compete
- Running the steps out of order

## Preflight checklist

Before proceeding, confirm:
- You have NOT read any source files yet
- You have the task description extracted from the user's message
- You are about to run `agx spawn`, not explore code

If you have already started reading code, STOP and proceed with step 1 anyway.

## 1. Setup (DO THIS FIRST)

Your very first action must be running these commands. Do not explore the codebase or plan the implementation — the teammates will do that.

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

Use `TeamCreate` to create a team, then spawn one teammate per exploration using the `Agent` tool with `team_name`.

For each teammate:
- Use `subagent_type: "general-purpose"` (they need to edit files)
- Include `/agx-explore-teammate` in their prompt so they know how to use agx
- Tell them the task description, their exploration index, and worktree path

Example teammate prompt:
```
Your working directory is <worktree_path>.
You are agx exploration [1]. Your task: "<task description>".
Invoke /agx-explore-teammate then work on the task.
```

Launch all teammates in parallel (multiple Agent tool calls in one message). Run them in the background so you can monitor progress.

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
- For **multiple independent tasks** (not competing approaches to the same task), use `/agx-batch-lead` instead.
