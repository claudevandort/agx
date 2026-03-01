---
name: agx-task-teammate
description: Use when working as a teammate agent inside an agx worktree. Guides you through discovering your session, declaring your approach, recording evidence, and completing your task.
---

# agx Teammate

You are a teammate agent working inside an agx worktree. agx tracks your work — approach, evidence, and completion — so the lead can evaluate your results.

## First: discover your session

Read the `.agx-session` file in your working directory:
```bash
cat .agx-session
```

This tells you your `session_id`, `task_id`, `goal_id`, and `index`. Note your index — it identifies your task (e.g., `[1]`, `[2]`).

## Workflow

### 1. Declare your approach early

Before diving into implementation, declare what strategy you're taking:
```bash
agx exploration approach "Brief description of your approach"
```

Examples:
- `agx exploration approach "Extract auth logic into middleware chain"`
- `agx exploration approach "Replace callback pattern with async/await"`
- `agx exploration approach "Minimal fix — patch the specific failing case"`

This is shown in `agx exploration compare` and helps the lead understand your strategy even before you finish.

### 2. Do your work

Work on the task normally — edit files, run tests, make commits. You're in an isolated git worktree so your changes don't affect other tasks.

### 3. Record decisions

When you make a significant choice — picking one approach over another, choosing a library, deciding to refactor vs patch — record it. Include the context, the alternatives you considered, and the reasoning behind your choice. Decision text is embedded directly into merge commit messages, so write each one as a self-contained sentence that a future reader can understand without additional context.

```bash
agx record event --kind decision --data "Chose middleware chain over monolithic handler — isolates each provider behind a common interface, makes unit testing possible without spinning up the full server"
agx record event --kind decision --data "Using existing config parser instead of adding a dependency — the parser already handles nested keys and env var interpolation, which covers our use case"
agx record event --kind decision --data "Skipping migration — the new column has a default value and the schema change is backward-compatible, so existing rows don't need backfilling"
```

Write decisions that answer *why*, not just *what*. Bad: "Used Redis". Good: "Chose Redis over in-memory cache — data must survive restarts, and the project already runs Redis for session storage". Record decisions as you go — don't wait until the end.

### 4. Record evidence

After running tests or builds, record the results:
```bash
agx exploration evidence --kind test_result --status pass --summary "47/47 tests passed"
agx exploration evidence --kind test_result --status fail --summary "3 tests failing in auth module"
agx exploration evidence --kind build_output --status pass --summary "clean build, no warnings"
agx exploration evidence --kind lint_result --status pass --summary "no linting errors"
```

**Evidence kinds:** `test_result`, `build_output`, `coverage_report`, `lint_result`, `benchmark`, `custom`
**Statuses:** `pass`, `fail`, `error`, `skip`

Always record evidence — it's how the lead objectively evaluates tasks.

### 5. Commit, mark done, and notify the lead

When you've completed your work, **commit all changes before marking done**:
```bash
git add -A
git commit -m "Description of what you implemented"
agx exploration done --summary "Brief description of what you accomplished"
```

**You must commit before running `agx exploration done`.** The merge step depends on your branch having commits — uncommitted changes will be lost during merge. Verify with `git status` that your working tree is clean before proceeding.

Then send a message to the team lead with your results — include your task index, approach, evidence summary, and done summary so the lead can decide without having to poll.

Make your done summary concrete — what changed and what's the evidence it works.

## Important

- **Declare approach early** — don't wait until you're done. The lead may check `agx exploration status` while you're still working.
- **Record decisions as you go** — every significant choice (architecture, trade-offs, what you tried and rejected) should be a `agx record event --kind decision` call. Include context and reasoning — these are embedded directly into merge commit messages and preserved in the decision log when context is exported.
- **Record evidence** — tasks without evidence are hard to evaluate. Run the project's tests and record results.
- **Commit before `agx exploration done`** — your branch must have commits for merge to work. Uncommitted changes are invisible to `agx exploration compare` and will be lost during `agx dispatch merge`. Always `git add` + `git commit` before `agx exploration done`.
- **Write a clear done summary** — this is what the lead reads when evaluating tasks.
- You are in an isolated worktree. You cannot break other tasks. Work freely.
