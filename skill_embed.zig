// Compile-time embedded skill files.
// Must live in project root so @embedFile can reach .claude/ paths.

pub const agx_explore_lead = @embedFile(".claude/skills/agx-explore-lead/SKILL.md");
pub const agx_task_teammate = @embedFile(".claude/skills/agx-task-teammate/SKILL.md");
pub const agx_dispatch_lead = @embedFile(".claude/skills/agx-dispatch-lead/SKILL.md");
