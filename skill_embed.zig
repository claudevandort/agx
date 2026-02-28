// Compile-time embedded skill files.
// Must live in project root so @embedFile can reach .claude/ paths.

pub const agx_lead = @embedFile(".claude/skills/agx-lead/SKILL.md");
pub const agx_teammate = @embedFile(".claude/skills/agx-teammate/SKILL.md");
