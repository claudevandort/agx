const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const fm_mod = agx.frontmatter;
const Frontmatter = fm_mod.Frontmatter;

/// `agx context` — query archived exploration context in `.agx/context/`.
/// No database dependency — works in any repo that has `.agx/context/` from git.
///
/// Subcommands:
///   list                  Show a table of all archived task contexts
///   search <query>        Search across context files (metadata + content)

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    // Find repo root via git
    const git = agx.GitCli.init(aa, null);
    const repo_root = git.repoRoot() catch {
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
        \\  list                    List archived task contexts
        \\  search <query>          Search context files
        \\
        \\List options:
        \\  --status <status>       Filter by task status (active, resolved, abandoned)
        \\
        \\Search options:
        \\  --task <id>             Filter by task ID prefix
        \\  --status <status>       Filter by task status
        \\
    , .{});
}

// ── Context directory scanning ──

const ContextEntry = struct {
    dir_name: []const u8,
    fm: Frontmatter,
    body: []const u8,
    full_content: []const u8,
};

/// Scan .agx/context/ for task directories containing summary.md with frontmatter.
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
    try stdout.print("{s:<28} {s:<12} {s:<20} {s}\n", .{ "TASK ID", "STATUS", "BRANCH", "DESCRIPTION" });
    try stdout.print("{s:<28} {s:<12} {s:<20} {s}\n", .{ "-------", "------", "------", "-----------" });

    for (entries) |entry| {
        // Apply status filter
        if (status_filter) |sf| {
            if (entry.fm.status) |st| {
                if (!std.ascii.eqlIgnoreCase(sf, st)) continue;
            } else continue;
        }

        const task_id = entry.fm.task_id orelse entry.dir_name;
        const status = entry.fm.status orelse "-";
        const branch = entry.fm.base_branch orelse "-";
        const desc = entry.fm.description orelse "-";

        // Truncate long descriptions
        const max_desc: usize = 50;
        const desc_display = if (desc.len > max_desc) desc[0..max_desc] else desc;

        try stdout.print("{s:<28} {s:<12} {s:<20} {s}\n", .{ task_id, status, branch, desc_display });
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
    // Parse args: search <query> [--task <id>] [--status <status>]
    var query: ?[]const u8 = null;
    var task_filter: ?[]const u8 = null;
    var status_filter: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--task")) {
            i += 1;
            if (i < args.len) task_filter = args[i];
        } else if (std.mem.eql(u8, args[i], "--status")) {
            i += 1;
            if (i < args.len) status_filter = args[i];
        } else if (query == null) {
            query = args[i];
        }
    }

    if (query == null and task_filter == null and status_filter == null) {
        try stderr.print("agx context search: no query or filters provided\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const entries = try scanContextDir(aa, context_dir);

    if (entries.len == 0) {
        try stderr.print("No context found in .agx/context/\n", .{});
        try stderr.flush();
        return;
    }

    var match_count: usize = 0;

    for (entries) |entry| {
        // Apply metadata filters
        if (task_filter) |tf| {
            const eid = entry.fm.task_id orelse entry.dir_name;
            if (!fm_mod.prefixMatch(eid, tf)) continue;
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
        const task_id = entry.fm.task_id orelse entry.dir_name;
        const desc = entry.fm.description orelse "-";
        const status = entry.fm.status orelse "-";

        try stdout.print("--- {s} ({s}) ---\n", .{ task_id, status });
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
