# Task 01KJG0: Add agx context search: a new 'agx context' command with 'list' and 'search' subcommands to query across archived exploration context in .agx/context/. Must add context.zig to src/cli/, register it in main.zig, and include tests.

- Base branch: master
- Base commit: b2025f2d9c36a3dc32188d1b693359f69e6fc163
- Status: active

## Explorations

### [1] ✓ done

- Branch: agx/01KJG0/1
- Approach: Grep-based file search: implement agx context list/search by scanning .agx/context/ filesystem directly with string matching, no database
- Summary: Added agx context command with list and search subcommands. Grep-based filesystem search over .agx/context/ directories. Includes case-insensitive matching, JSON output, and 5 unit tests.

### [2] ✓ done

- Branch: agx/01KJG0/2
- Approach: FTS5 full-text search via SQLite — add context_fts FTS5 virtual table, populate during export, implement agx context list/search with ranked results and snippets
- Summary: Added agx context command with FTS5 full-text search. Migration 3 creates context_fts virtual table with porter stemming. Export populates index automatically. Search returns ranked results with snippets. List shows all archived explorations grouped by task. Both support --json output. 4 new tests pass.

### [3] ★ kept

- Branch: agx/01KJG0/3
- Approach: Standalone context files with structured filtering — rework export to write self-contained files with YAML-style frontmatter metadata, implement agx context list (scans .agx/context/ and parses frontmatter to show table), and agx context search (metadata filtering + content grep). No database dependency.
- Summary: Added agx context command with list and search subcommands. Standalone approach: export.zig writes YAML frontmatter to summary.md, frontmatter.zig provides shared parser (with tests), context.zig scans .agx/context/ without database dependency. Supports --status/--task filters and case-insensitive content search. Build + tests + smoke tests all pass.

