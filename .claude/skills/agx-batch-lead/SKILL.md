---
name: agx-batch-lead
description: REQUIRED workflow for running multiple independent tasks in parallel. Do NOT implement tasks yourself — create a batch and spawn teammate agents. Each task runs in its own worktree, then results are merged sequentially with conflict-aware ordering.
---

# agx Batch Lead

You are the **lead coordinator**, NOT the implementer. Your job is to create a batch, spawn teammate agents, monitor their progress, and merge the results. The teammates do the actual coding.

## IMPORTANT: Do NOT implement the tasks yourself

- Do NOT read source files to "understand the codebase" before creating the batch
- Do NOT use Edit/Write tools to implement any task
- Do NOT skip the team because "the tasks overlap too much" — that is exactly what the merge ordering and conflict resolution steps handle
- If you catch yourself exploring the codebase to plan an implementation, STOP and proceed with step 1

## Anti-patterns (do NOT do these)

- Reading source files before creating the batch
- Implementing tasks yourself instead of spawning teammates
- Skipping the team because tasks touch the same files
- Exploring the codebase "to understand the problem" — the teammates will do that
- Running the steps out of order

## Preflight checklist

Before proceeding, confirm:
- You have NOT read any source files yet
- You have the task descriptions extracted from the user's message
- You are about to run `agx batch create`, not explore code

If you have already started reading code, STOP and proceed with step 1 anyway.

## 1. Create the batch (DO THIS FIRST)

Your very first action must be running this command. Do not explore the codebase or plan the implementation — the teammates will do that.

```bash
agx init   # if not already initialized
agx batch create --tasks "task 1 description" "task 2 description" "task 3 description" --policy semi
```

Policy options:
- `autonomous` — you resolve all merge conflicts yourself
- `semi` — you resolve trivial conflicts, ask the user for complex ones
- `manual` — every conflict goes to the user

Check what was created:
```bash
agx batch status
```

## 2. Create a team and launch teammates

Use `TeamCreate` to create a team, then spawn one teammate per task using the `Agent` tool with `team_name`.

For each teammate:
- Set `subagent_type: "general-purpose"`
- Set `isolation: "worktree"` is NOT needed — agx already created worktrees
- Tell the teammate which worktree to `cd` into
- Tell the teammate to use the `/agx-explore-teammate` skill
- Give the teammate the task description

Example teammate prompt:
```
You are working on a task in an agx batch. cd into <worktree_path> and invoke the /agx-explore-teammate skill.

Your task: <task description>

When done, run `agx done` from inside the worktree and send me a message.
```

## 3. Monitor progress

Check batch and task status:
```bash
agx batch status
```

Wait for all teammates to report completion. Each teammate should run `agx done` when finished.

## 4. Dry-run merge

Before merging, preview the merge order and file overlap:
```bash
agx batch merge --dry-run
```

This shows:
- The computed merge order (least overlapping files first)
- File overlap matrix between tasks
- No actual merges are performed

Review the output. If the order looks wrong or there's heavy overlap, consider adjusting.

## 5. Execute merge

```bash
agx batch merge
```

This will:
1. Checkout the base branch
2. Merge each task's branch in the computed order, tracking progress
3. Commit each clean merge with AGX-Batch and AGX-Task trailers
4. Pause on conflicts — batch enters `conflict` status until resolved with `--continue`

### Conflict resolution

**MANDATORY**: When a merge has conflicts, you MUST stop and ask the user before resolving. Do NOT resolve conflicts silently — even if they look trivial. Use AskUserQuestion every time.

For each conflicted merge step:

1. Show the user which files have conflicts and a brief summary of what both sides changed
2. Ask the user using AskUserQuestion with these options:
   - **"Autonomous"** — you read the conflicted files, understand both tasks' intent, resolve the conflicts, and continue
   - **"Manual"** — you show the full conflict markers to the user and wait for them to resolve and tell you when done
3. Only proceed with resolution after the user responds

Do NOT batch multiple conflict resolutions into a single question — ask per merge step so the user can choose differently for each one.

**After autonomous resolution**: Read the conflicted files, understand both tasks' intent from their approach/evidence, edit files to resolve, then:
```bash
git add <resolved files>
agx batch merge --continue
```

**After manual resolution**: Show all conflict markers to the user. Wait for them to confirm resolution, then:
```bash
agx batch merge --continue
```

`--continue` commits the resolved merge, updates progress, and continues merging remaining tasks. On another conflict, the batch pauses again — repeat this process.

Do NOT use raw `git commit` to commit resolved conflicts — always use `agx batch merge --continue` so the batch tracks progress correctly.

## 6. Export context

After all tasks have been merged successfully, export decision logs, evidence, and session history to `.agx/context/` so future agents can see what was done and why:

```bash
agx context export --batch <batch_id>
```

This exports per-task context plus a batch-level summary to `.agx/context/`, tracked in git and shared with the team.

## 7. Cleanup

After exporting context, shut down teammates and clean up:
```bash
agx clean
```

## Key differences from /agx-explore-lead

- `/agx-explore-lead`: One task, N explorations of the same goal — pick the best one
- `/agx-batch-lead`: N different tasks, each with one exploration — merge them all together
