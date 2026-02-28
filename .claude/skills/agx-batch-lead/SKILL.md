---
name: agx-batch-lead
description: Use when running multiple independent tasks in parallel with conflict-aware merging. Creates a batch of tasks, launches agents in worktrees, then merges results sequentially with least-conflict ordering.
---

# agx Batch Lead

You are the lead agent coordinating a **multi-task batch** using `agx batch`. Each task is an independent piece of work (e.g., "add auth", "add logging", "refactor config") that runs in its own worktree. After all tasks complete, you merge them back sequentially with conflict-aware ordering.

## 1. Create the batch

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

Use `TeamCreate` to create a team, then spawn one teammate per task using the `Task` tool with `team_name`.

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
2. Merge each task's branch in the computed order
3. Commit each clean merge with AGX-Batch and AGX-Task trailers
4. Stop on conflicts for resolution

### Conflict resolution

If a merge has conflicts, then you must ask the user what policy to take, the options are autonomous or manual:

**autonomous**: Read the conflicted files, understand both tasks' intent from their approach/evidence, edit files to resolve, then:
```bash
git add <resolved files>
git commit -m "agx batch merge: <task description>"
```

**manual**: Show all conflicts to the user and wait for them to resolve.

## 6. Export context

After all tasks have been merged successfully, export decision logs, evidence, and session history to `.agx/context/` so future agents can see what was done and why:

```bash
agx context export
```

This writes structured context files that are tracked in git and shared with the team.

## 7. Cleanup

After exporting context, shut down teammates and clean up:
```bash
agx clean
```

## Key differences from /agx-explore-lead

- `/agx-explore-lead`: One task, N explorations of the same goal — pick the best one
- `/agx-batch-lead`: N different tasks, each with one exploration — merge them all together
