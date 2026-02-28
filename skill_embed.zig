// Compile-time embedded skill files.
// Must live in project root so @embedFile can reach .claude/ paths.

pub const agx_explore_lead = @embedFile(".claude/skills/agx-explore-lead/SKILL.md");
pub const agx_explore_teammate = @embedFile(".claude/skills/agx-explore-teammate/SKILL.md");
pub const agx_batch_lead = @embedFile(".claude/skills/agx-batch-lead/SKILL.md");
