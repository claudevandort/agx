---
name: agx-explore-teammate
description: Use when working as a teammate agent inside an agx exploration worktree. Guides you through discovering your session, declaring your approach, recording evidence, and completing your exploration.
---

# agx Teammate

You are a teammate agent working inside an agx exploration worktree. agx tracks your work — approach, evidence, and completion — so the orchestrator can compare your results against other parallel explorations of the same task.

## First: discover your session

Read the `.agx-session` file in your working directory:
```bash
cat .agx-session
```

This tells you your `session_id`, `exploration_id`, `task_id`, and `index`. Note your index — it identifies your exploration (e.g., `[1]`, `[2]`).

## Workflow

### 1. Declare your approach early

Before diving into implementation, declare what strategy you're taking:
```bash
agx approach "Brief description of your approach"
```

Examples:
- `agx approach "Extract auth logic into middleware chain"`
- `agx approach "Replace callback pattern with async/await"`
- `agx approach "Minimal fix — patch the specific failing case"`

This is shown in `agx compare` and helps the orchestrator understand your strategy even before you finish.

### 2. Do your work

Work on the task normally — edit files, run tests, make commits. You're in an isolated git worktree so your changes don't affect other explorations.

### 3. Record decisions

When you make a significant choice — picking one approach over another, choosing a library, deciding to refactor vs patch — record it:
```bash
agx record --kind decision "Chose middleware chain over monolithic handler for testability"
agx record --kind decision "Using existing config parser instead of adding a dependency"
agx record --kind decision "Skipping migration — schema change is backward-compatible"
```

These feed into the decision log, which helps the orchestrator understand *why* you did what you did, not just *what* you did. Record decisions as you go — don't wait until the end.

### 4. Record evidence

After running tests or builds, record the results:
```bash
agx evidence --kind test_result --status pass --summary "47/47 tests passed"
agx evidence --kind test_result --status fail --summary "3 tests failing in auth module"
agx evidence --kind build_output --status pass --summary "clean build, no warnings"
agx evidence --kind lint_result --status pass --summary "no linting errors"
```

**Evidence kinds:** `test_result`, `build_output`, `coverage_report`, `lint_result`, `benchmark`, `custom`
**Statuses:** `pass`, `fail`, `error`, `skip`

Always record evidence — it's how the orchestrator objectively compares explorations.

### 5. Mark done and notify the lead

When you've completed your work:
```bash
agx done --summary "Brief description of what you accomplished"
```

Then send a message to the team lead with your results — include your exploration index, approach, evidence summary, and done summary so the lead can decide without having to poll.

Make your done summary concrete — what changed and what's the evidence it works.

## Important

- **Declare approach early** — don't wait until you're done. The orchestrator may check `agx status` while you're still working.
- **Record decisions as you go** — every significant choice (architecture, trade-offs, what you tried and rejected) should be a `agx record --kind decision` call. These are preserved in the decision log when context is exported.
- **Record evidence** — explorations without evidence are hard to evaluate. Run the project's tests and record results.
- **Commit your work** — `agx compare` uses git diff stats. Make sure your changes are committed.
- **Write a clear done summary** — this is what the orchestrator reads when comparing explorations.
- You are in an isolated worktree. You cannot break other explorations. Work freely.
