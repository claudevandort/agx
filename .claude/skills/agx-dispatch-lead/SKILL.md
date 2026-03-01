---
name: agx-dispatch-lead
description: REQUIRED workflow for running multiple independent goals in parallel. Do NOT implement goals yourself — create a dispatch and spawn teammate agents. Each goal runs in its own worktree, then results are merged sequentially with conflict-aware ordering.
---

# agx Dispatch Lead

You are the **lead coordinator**, NOT the implementer. Your job is to create a dispatch, spawn teammate agents, monitor their progress, and merge the results. The teammates do the actual coding.

## IMPORTANT: Do NOT implement the goals yourself

- Do NOT read source files to "understand the codebase" before creating the dispatch
- Do NOT use Edit/Write tools to implement any goal
- Do NOT skip the team because "the goals overlap too much" — that is exactly what the merge ordering and conflict resolution steps handle
- If you catch yourself exploring the codebase to plan an implementation, STOP and proceed with step 1

## Anti-patterns (do NOT do these)

- Reading source files before creating the dispatch
- Implementing goals yourself instead of spawning teammates
- Skipping the team because goals touch the same files
- Exploring the codebase "to understand the problem" — the teammates will do that
- Running the steps out of order

## Preflight checklist

Before proceeding, confirm:
- You have NOT read any source files yet
- You have the goal descriptions extracted from the user's message
- You are about to run `agx dispatch create`, not explore code

If you have already started reading code, STOP and proceed with step 1 anyway.

## 1. Create the dispatch (DO THIS FIRST)

Your very first action must be running this command. Do not explore the codebase or plan the implementation — the teammates will do that.

```bash
agx init   # if not already initialized
agx dispatch create --goals "goal 1 description" "goal 2 description" "goal 3 description" --policy semi
```

Policy options:
- `autonomous` — you resolve all merge conflicts yourself
- `semi` — you resolve trivial conflicts, ask the user for complex ones
- `manual` — every conflict goes to the user

Check what was created:
```bash
agx dispatch status
```

## 2. Create a team and launch teammates

Use `TeamCreate` to create a team, then spawn one teammate per goal using the `Agent` tool with `team_name`.

For each teammate:
- Set `subagent_type: "general-purpose"`
- Set `isolation: "worktree"` is NOT needed — agx already created worktrees
- Tell the teammate which worktree to `cd` into
- Tell the teammate to use the `/agx-task-teammate` skill
- Give the teammate the goal description

Example teammate prompt:
```
You are working on a goal in an agx dispatch. cd into <worktree_path> and invoke the /agx-task-teammate skill.

Your goal: <goal description>

When done, run `agx exploration done` from inside the worktree and send me a message.
```

## 3. Monitor progress

Check dispatch and goal status:
```bash
agx dispatch status
```

Wait for all teammates to report completion. Each teammate should run `agx exploration done` when finished.

## 4. Dry-run merge

Before merging, preview the merge order and file overlap:
```bash
agx dispatch merge --dry-run
```

This shows:
- The computed merge order (least overlapping files first)
- File overlap matrix between goals
- No actual merges are performed

Review the output. If the order looks wrong or there's heavy overlap, consider adjusting.

## 5. Execute merge

```bash
agx dispatch merge
```

This will:
1. Checkout the base branch
2. Merge each goal's branch in the computed order, tracking progress
3. Commit each clean merge with AGX-Dispatch and AGX-Goal trailers
4. Pause on conflicts — dispatch enters `conflict` status until resolved with `--continue`

### Conflict resolution

**MANDATORY**: When a merge has conflicts, you MUST stop and ask the user before resolving. Do NOT resolve conflicts silently — even if they look trivial. Use AskUserQuestion every time.

For each conflicted merge step:

1. Show the user which files have conflicts and a brief summary of what both sides changed
2. Ask the user using AskUserQuestion with these options:
   - **"Autonomous"** — you read the conflicted files, understand both goals' intent, resolve the conflicts, and continue
   - **"Manual"** — you show the full conflict markers to the user and wait for them to resolve and tell you when done
3. Only proceed with resolution after the user responds

Do NOT batch multiple conflict resolutions into a single question — ask per merge step so the user can choose differently for each one.

**After autonomous resolution**: Read the conflicted files, understand both goals' intent from their approach/evidence, edit files to resolve, then:
```bash
git add <resolved files>
agx dispatch merge --continue
```

**After manual resolution**: Show all conflict markers to the user. Wait for them to confirm resolution, then:
```bash
agx dispatch merge --continue
```

`--continue` commits the resolved merge, updates progress, and continues merging remaining goals. On another conflict, the dispatch pauses again — repeat this process.

Do NOT use raw `git commit` to commit resolved conflicts — always use `agx dispatch merge --continue` so the dispatch tracks progress correctly.

## 6. Export context

After all goals have been merged successfully, export decision logs, evidence, and session history to `.agx/context/` so future agents can see what was done and why:

```bash
agx context export --dispatch <dispatch_id>
```

This exports per-goal context plus a dispatch-level summary to `.agx/context/`, tracked in git and shared with the team.

## 7. Cleanup

After exporting context, shut down teammates and clean up:
```bash
agx exploration clean
```

## Important

- **Never change the working directory.** Always run `agx` and `git` commands from the repository root. When inspecting worktree contents, use absolute paths (e.g., `git -C <worktree_path> diff`) or prefix with `cd /path/to/repo &&`. Never `cd` into a worktree — subsequent `agx` commands will fail with "agx not initialized" because the cwd is no longer the repo root.

## Key differences from /agx-explore-lead

- `/agx-explore-lead`: One goal, N tasks competing with different approaches — pick the best one
- `/agx-dispatch-lead`: N different goals, each with one task — merge them all together
