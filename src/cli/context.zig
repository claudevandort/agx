const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const fm_mod = agx.frontmatter;
const Frontmatter = fm_mod.Frontmatter;
const CliContext = @import("cli_common.zig").CliContext;
const JsonWriter = agx.json_writer.JsonWriter;

/// `agx context` — query archived task context in `.agx/context/`.
/// Uses FTS5 full-text search when a database is available, falls back to
/// file-based substring matching otherwise.
///
/// Subcommands:
///   list                  Show a table of all archived goal contexts
///   search <query>        Search across context files (metadata + content)
///   reindex               Rebuild the FTS search index

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    // Find repo root via git
    const git_ = agx.GitCli.init(aa, null);
    const repo_root = git_.repoRoot() catch {
        try stderr.print("error: not a git repository\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    const context_dir = std.fmt.allocPrint(aa, "{s}/.agx/context", .{repo_root}) catch {
        try stderr.print("error: out of memory\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    if (args.len == 0) {
        try printUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    }

    const subcmd = args[0];
    const sub_args = args[1..];

    if (std.mem.eql(u8, subcmd, "list")) {
        try runList(aa, context_dir, sub_args, stdout, stderr);
    } else if (std.mem.eql(u8, subcmd, "search")) {
        try runSearch(aa, context_dir, sub_args, stdout, stderr);
    } else if (std.mem.eql(u8, subcmd, "reindex")) {
        try runReindex(aa, context_dir, stdout, stderr);
    } else if (std.mem.eql(u8, subcmd, "export")) {
        try runExport(aa, context_dir, sub_args, stdout, stderr);
    } else {
        try stderr.print("agx context: unknown subcommand '{s}'\n", .{subcmd});
        try printUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    }

    try stdout.flush();
}

fn printUsage(w: *std.Io.Writer) !void {
    try w.print(
        \\Usage: agx context <subcommand> [options]
        \\
        \\Subcommands:
        \\  export [--goal <id>] [--dispatch <id>]
        \\                          Export goal or dispatch context to .agx/context/
        \\  list                    List archived goal contexts
        \\  search <query>          Search context files (FTS5 ranked search)
        \\  reindex                 Rebuild the FTS search index
        \\
        \\List options:
        \\  --status <status>       Filter by goal status (active, resolved, abandoned)
        \\
        \\Search options:
        \\  --json                  Output results as JSON (for LLM piping)
        \\  --limit N               Max results (default 20)
        \\  --goal <id>             Filter by goal ID prefix (file-based fallback only)
        \\  --status <status>       Filter by goal status (file-based fallback only)
        \\
    , .{});
}

// ── export subcommand ──

fn runExport(
    aa: Allocator,
    context_dir: []const u8,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    _ = context_dir;

    var goal_filter: ?[]const u8 = null;
    var dispatch_filter: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--goal")) {
            i += 1;
            if (i < args.len) {
                goal_filter = args[i];
            } else {
                try stderr.print("error: --goal requires a goal ID prefix\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, args[i], "--dispatch")) {
            i += 1;
            if (i < args.len) {
                dispatch_filter = args[i];
            } else {
                try stderr.print("error: --dispatch requires a dispatch ID prefix\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
        }
    }

    if (goal_filter != null and dispatch_filter != null) {
        try stderr.print("error: --goal and --dispatch are mutually exclusive\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    var ctx = CliContext.open(aa, stderr);
    defer ctx.deinit();

    if (dispatch_filter) |prefix| {
        // Find dispatch by prefix match
        var dispatch_buf: [32]agx.Dispatch = undefined;
        const all_dispatches = ctx.store.getAllDispatches(&dispatch_buf) catch {
            try stderr.print("error: could not query dispatches\n", .{});
            try stderr.flush();
            std.process.exit(1);
        };

        var matched: ?agx.Dispatch = null;
        for (all_dispatches) |d| {
            const enc = d.id.encode();
            if (std.mem.startsWith(u8, &enc, prefix)) {
                if (matched != null) {
                    try stderr.print("error: ambiguous dispatch prefix '{s}' — matches multiple dispatches\n", .{prefix});
                    try stderr.flush();
                    std.process.exit(1);
                }
                matched = d;
            }
        }

        if (matched) |d| {
            if (agx.context_export.exportDispatchContext(aa, &ctx.store, &d, ".agx/context")) |dir| {
                try stdout.print("Dispatch context exported to {s}\n", .{dir});
            } else |err| {
                try stderr.print("error: could not export dispatch context: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            }
        } else {
            try stderr.print("error: no dispatch matching prefix '{s}'\n", .{prefix});
            try stderr.flush();
            std.process.exit(1);
        }
    } else if (goal_filter) |prefix| {
        // Find goal by prefix match
        var goal_buf: [64]agx.Goal = undefined;
        const all_goals = ctx.store.getAllGoals(&goal_buf) catch {
            try stderr.print("error: could not query goals\n", .{});
            try stderr.flush();
            std.process.exit(1);
        };

        var matched: ?agx.Goal = null;
        for (all_goals) |g| {
            const enc = g.id.encode();
            if (std.mem.startsWith(u8, &enc, prefix)) {
                if (matched != null) {
                    try stderr.print("error: ambiguous goal prefix '{s}' — matches multiple goals\n", .{prefix});
                    try stderr.flush();
                    std.process.exit(1);
                }
                matched = g;
            }
        }

        if (matched) |g| {
            if (agx.context_export.exportGoalContext(aa, &ctx.store, &g, ".agx/context")) |dir| {
                try stdout.print("Context exported to {s}\n", .{dir});
            } else |err| {
                try stderr.print("error: could not export context: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            }
        } else {
            try stderr.print("error: no goal matching prefix '{s}'\n", .{prefix});
            try stderr.flush();
            std.process.exit(1);
        }
    } else {
        // Default: export active goal
        const g = ctx.store.getActiveGoal() catch {
            try stderr.print("error: no active goal found (use --goal <id> to specify)\n", .{});
            try stderr.flush();
            std.process.exit(1);
        };

        if (agx.context_export.exportGoalContext(aa, &ctx.store, &g, ".agx/context")) |dir| {
            try stdout.print("Context exported to {s}\n", .{dir});
        } else |err| {
            try stderr.print("error: could not export context: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        }
    }
}

// ── Context directory scanning ──

const ContextEntry = struct {
    dir_name: []const u8,
    fm: Frontmatter,
    body: []const u8,
    full_content: []const u8,
};

/// Scan .agx/context/ for goal directories containing summary.md with frontmatter.
fn scanContextDir(aa: Allocator, context_dir: []const u8) ![]ContextEntry {
    var entries = std.ArrayList(ContextEntry).empty;

    var dir = std.fs.cwd().openDir(context_dir, .{ .iterate = true }) catch return entries.items;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        const summary_path = try std.fmt.allocPrint(aa, "{s}/{s}/summary.md", .{ context_dir, entry.name });
        const content = std.fs.cwd().readFileAlloc(aa, summary_path, 1024 * 1024) catch continue;
        const parsed = fm_mod.parseFrontmatter(content);

        try entries.append(aa, .{
            .dir_name = try aa.dupe(u8, entry.name),
            .fm = parsed.fm,
            .body = content[parsed.body_start..],
            .full_content = content,
        });
    }

    return entries.items;
}

// ── list subcommand ──

fn runList(
    aa: Allocator,
    context_dir: []const u8,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    // Parse --status filter
    var status_filter: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--status")) {
            i += 1;
            if (i < args.len) status_filter = args[i];
        }
    }

    const entries = try scanContextDir(aa, context_dir);

    if (entries.len == 0) {
        try stderr.print("No context found in .agx/context/\n", .{});
        try stderr.flush();
        return;
    }

    // Print header
    try stdout.print("{s:<28} {s:<12} {s:<20} {s}\n", .{ "GOAL ID", "STATUS", "BRANCH", "DESCRIPTION" });
    try stdout.print("{s:<28} {s:<12} {s:<20} {s}\n", .{ "-------", "------", "------", "-----------" });

    for (entries) |entry| {
        // Apply status filter
        if (status_filter) |sf| {
            if (entry.fm.status) |st| {
                if (!std.ascii.eqlIgnoreCase(sf, st)) continue;
            } else continue;
        }

        const goal_id = entry.fm.task_id orelse entry.dir_name;
        const status = entry.fm.status orelse "-";
        const branch = entry.fm.base_branch orelse "-";
        const desc = entry.fm.description orelse "-";

        // Truncate long descriptions
        const max_desc: usize = 50;
        const desc_display = if (desc.len > max_desc) desc[0..max_desc] else desc;

        try stdout.print("{s:<28} {s:<12} {s:<20} {s}\n", .{ goal_id, status, branch, desc_display });
    }
}

// ── search subcommand ──

fn runSearch(
    aa: Allocator,
    context_dir: []const u8,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    // Parse args: search <query> [--json] [--limit N] [--goal <id>] [--status <status>]
    var query: ?[]const u8 = null;
    var goal_filter: ?[]const u8 = null;
    var status_filter: ?[]const u8 = null;
    var json_output = false;
    var limit: u32 = 20;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--goal")) {
            i += 1;
            if (i < args.len) goal_filter = args[i];
        } else if (std.mem.eql(u8, args[i], "--status")) {
            i += 1;
            if (i < args.len) status_filter = args[i];
        } else if (std.mem.eql(u8, args[i], "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, args[i], "--limit")) {
            i += 1;
            if (i < args.len) {
                limit = std.fmt.parseInt(u32, args[i], 10) catch 20;
            }
        } else if (query == null) {
            query = args[i];
        }
    }

    if (query == null and goal_filter == null and status_filter == null) {
        try stderr.print("agx context search: no query or filters provided\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    // Try FTS search if we have a query and DB is available
    if (query) |q| {
        if (tryFtsSearch(aa, q, limit, json_output, stdout, stderr)) return;
    }

    // Fallback: file-based search
    try runFileSearch(aa, context_dir, query, goal_filter, status_filter, stdout, stderr);
}

/// Attempt FTS5 search via the database. Returns true if successful.
fn tryFtsSearch(
    aa: Allocator,
    query: []const u8,
    limit: u32,
    json_output: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) bool {
    _ = stderr;
    var ctx = CliContext.openOptional(aa);
    if (ctx == null) return false;
    defer ctx.?.deinit();

    const capped_limit = if (limit > 100) @as(u32, 100) else limit;
    var result_buf: [100]agx.Store.SearchResult = undefined;
    const results = ctx.?.store.searchFts(query, result_buf[0..capped_limit]) catch return false;

    if (json_output) {
        var jw = JsonWriter.init(stdout);
        jw.beginObject() catch return false;
        jw.arrayField("results") catch return false;
        for (results) |r| {
            jw.beginObjectValue() catch return false;
            jw.stringField("type", r.entity_type) catch return false;
            jw.stringField("entity_id", r.entity_id) catch return false;
            jw.stringField("goal_id", r.task_id) catch return false;
            jw.stringField("snippet", r.snippet) catch return false;
            jw.floatField("rank", r.rank) catch return false;
            jw.endObject() catch return false;
        }
        jw.endArray() catch return false;
        jw.endObject() catch return false;
        stdout.print("\n", .{}) catch return false;
    } else {
        if (results.len == 0) {
            stdout.print("No matches found.\n", .{}) catch return false;
            return true;
        }
        for (results, 1..) |r, idx| {
            stdout.print("[{d}] {s}  {s}  ({d:.2})\n", .{ idx, r.entity_type, r.task_id, r.rank }) catch return false;
            stdout.print("    {s}\n", .{r.snippet}) catch return false;
        }
        stdout.print("\n{d} result(s).\n", .{results.len}) catch return false;
    }
    return true;
}

/// File-based search fallback (original behavior).
fn runFileSearch(
    aa: Allocator,
    context_dir: []const u8,
    query: ?[]const u8,
    goal_filter: ?[]const u8,
    status_filter: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const entries = try scanContextDir(aa, context_dir);

    if (entries.len == 0) {
        try stderr.print("No context found in .agx/context/\n", .{});
        try stderr.flush();
        return;
    }

    var match_count: usize = 0;

    for (entries) |entry| {
        // Apply metadata filters
        if (goal_filter) |gf| {
            const eid = entry.fm.task_id orelse entry.dir_name;
            if (!fm_mod.prefixMatch(eid, gf)) continue;
        }

        if (status_filter) |sf| {
            if (entry.fm.status) |st| {
                if (!std.ascii.eqlIgnoreCase(sf, st)) continue;
            } else continue;
        }

        // Content search (case-insensitive substring match)
        if (query) |q| {
            if (!fm_mod.containsIgnoreCase(entry.full_content, q)) continue;
        }

        // Print match
        match_count += 1;
        const goal_id = entry.fm.task_id orelse entry.dir_name;
        const desc = entry.fm.description orelse "-";
        const status = entry.fm.status orelse "-";

        try stdout.print("--- {s} ({s}) ---\n", .{ goal_id, status });
        try stdout.print("  {s}\n", .{desc});

        // If there was a text query, show matching lines from the body
        if (query) |q| {
            try printMatchingLines(entry.full_content, q, stdout);
        }
        try stdout.print("\n", .{});
    }

    if (match_count == 0) {
        try stderr.print("No matches found.\n", .{});
        try stderr.flush();
    } else {
        try stdout.print("{d} context(s) matched.\n", .{match_count});
    }
}

// ── reindex subcommand ──

fn runReindex(
    aa: Allocator,
    context_dir: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var ctx = CliContext.open(aa, stderr);
    defer ctx.deinit();

    // Index DB data
    ctx.store.indexForSearch() catch {
        try stderr.print("error: failed to index database\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    // Index context files
    ctx.store.indexContextFiles(context_dir) catch {
        try stderr.print("error: failed to index context files\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    const count = ctx.store.countFtsEntries() catch 0;
    try stdout.print("Indexed {d} entries.\n", .{count});
}

/// Print lines from content that contain the query (case-insensitive).
fn printMatchingLines(content: []const u8, query: []const u8, stdout: *std.Io.Writer) !void {
    var line_start: usize = 0;
    var shown: usize = 0;
    const max_lines: usize = 5;

    while (line_start < content.len and shown < max_lines) {
        const line_end = std.mem.indexOfScalar(u8, content[line_start..], '\n') orelse content.len - line_start;
        const line = content[line_start .. line_start + line_end];

        if (fm_mod.containsIgnoreCase(line, query)) {
            // Trim and print the matching line
            const trimmed = std.mem.trim(u8, line, &[_]u8{ ' ', '\t', '\r' });
            if (trimmed.len > 0) {
                const max_line_len: usize = 100;
                const display = if (trimmed.len > max_line_len) trimmed[0..max_line_len] else trimmed;
                try stdout.print("    > {s}\n", .{display});
                shown += 1;
            }
        }

        line_start += line_end + 1;
    }
}
