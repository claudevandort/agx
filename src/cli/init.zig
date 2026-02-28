const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const skill_files = @import("skill_files");

const claude_md_section =
    \\
    \\## When attempting to address multiple tasks
    \\
    \\Paralellize work taking a multi-agent approach (one agent per task) leveraging agent teams and using agx skills to facilitate the work between the team lead and the teammates. Depending on the nature of the request, use one of these skills to address it:
    \\
    \\- **`/agx-explore-lead`** — The user is giving one problem to solve and is asking to try different approaches or ways of implementing the solution. This skill includes instruction to spawn an agent team to try different approaches, compare results, and merge the winner.
    \\- **`/agx-batch-lead`** — The user is giving a list of problems to solve or features to implement (where there might be code overlap). This skill includes instructions to spawn an agent team to solve the list of tasks stated by the user, each agent taking one task each, and then merging everyone's changes sequentially.
    \\
;

const claude_md_full =
    \\# CLAUDE.md
    \\
    \\## When attempting to address multiple tasks
    \\
    \\Paralellize work taking a multi-agent approach (one agent per task) leveraging agent teams and using agx skills to facilitate the work between the team lead and the teammates. Depending on the nature of the request, use one of these skills to address it:
    \\
    \\- **`/agx-explore-lead`** — The user is giving one problem to solve and is asking to try different approaches or ways of implementing the solution. This skill includes instruction to spawn an agent team to try different approaches, compare results, and merge the winner.
    \\- **`/agx-batch-lead`** — The user is giving a list of problems to solve or features to implement (where there might be code overlap). This skill includes instructions to spawn an agent team to solve the list of tasks stated by the user, each agent taking one task each, and then merging everyone's changes sequentially.
    \\
;

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var shared = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--shared")) {
            shared = true;
        }
    }

    // Verify we're in a git repo
    const git = agx.GitCli.init(aa, null);
    const git_dir = git.gitDir() catch {
        try stderr.print("error: not a git repository\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    // Create .git/agx/ directory structure
    const dirs = [_][]const u8{
        "agx",
        "agx/cache",
        "agx/worktrees",
        "agx/evidence",
    };

    for (dirs) |sub| {
        const full = try std.fmt.allocPrint(aa, "{s}/{s}", .{ git_dir, sub });
        std.fs.cwd().makePath(full) catch |err| {
            try stderr.print("error: could not create {s}: {s}\n", .{ full, @errorName(err) });
            try stderr.flush();
            std.process.exit(1);
        };
    }

    // Initialize the SQLite database
    const db_path = try std.fmt.allocPrintSentinel(aa, "{s}/agx/db.sqlite3", .{git_dir}, 0);

    var store = try agx.Store.init(aa, db_path);
    store.deinit();

    try stdout.print("Initialized agx in {s}/agx/\n", .{git_dir});

    // Get repo root for CLAUDE.md and skill files
    const repo_root = git.repoRoot() catch {
        // Non-fatal — core init succeeded
        try finishShared(shared, stdout, stderr);
        return;
    };

    // Create/update CLAUDE.md
    createOrUpdateClaudeMd(aa, repo_root, stdout) catch |err| {
        try stderr.print("warning: could not create CLAUDE.md: {s}\n", .{@errorName(err)});
        try stderr.flush();
    };

    // Create skill files
    createSkillFile(aa, repo_root, "agx-explore-lead", skill_files.agx_explore_lead, stdout) catch |err| {
        try stderr.print("warning: could not create agx-explore-lead skill: {s}\n", .{@errorName(err)});
        try stderr.flush();
    };
    createSkillFile(aa, repo_root, "agx-explore-teammate", skill_files.agx_explore_teammate, stdout) catch |err| {
        try stderr.print("warning: could not create agx-explore-teammate skill: {s}\n", .{@errorName(err)});
        try stderr.flush();
    };
    createSkillFile(aa, repo_root, "agx-batch-lead", skill_files.agx_batch_lead, stdout) catch |err| {
        try stderr.print("warning: could not create agx-batch-lead skill: {s}\n", .{@errorName(err)});
        try stderr.flush();
    };

    try finishShared(shared, stdout, stderr);
}

fn finishShared(shared: bool, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    _ = stderr;
    // Create .agx/ for team sharing if --shared
    if (shared) {
        const shared_dirs = [_][]const u8{
            ".agx",
            ".agx/context",
        };
        for (shared_dirs) |dir| {
            std.fs.cwd().makePath(dir) catch |err| {
                try stdout.print("error: could not create {s}: {s}\n", .{ dir, @errorName(err) });
                try stdout.flush();
                std.process.exit(1);
            };
        }

        // Create shared config.toml if it doesn't exist
        const config_file = std.fs.cwd().createFile(".agx/config.toml", .{ .exclusive = true }) catch |err| {
            if (err == error.PathAlreadyExists) {
                try stdout.print("Created .agx/ for team sharing\n", .{});
                try stdout.flush();
                return;
            }
            return err;
        };
        defer config_file.close();

        var config_buf: [256]u8 = undefined;
        var config_writer = config_file.writer(&config_buf);
        try config_writer.interface.print("# agx shared configuration\n", .{});
        try config_writer.interface.flush();

        try stdout.print("Created .agx/ for team sharing\n", .{});
    }

    try stdout.flush();
}

fn createOrUpdateClaudeMd(alloc: Allocator, repo_root: []const u8, stdout: *std.Io.Writer) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/CLAUDE.md", .{repo_root});

    // Try to read existing file
    const existing = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            // Create new CLAUDE.md
            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();
            var buf: [4096]u8 = undefined;
            var writer = file.writer(&buf);
            try writer.interface.writeAll(claude_md_full);
            try writer.interface.flush();
            try stdout.print("Created CLAUDE.md with agx instructions\n", .{});
            return;
        }
        return err;
    };

    // File exists — check if it already has agx content
    if (std.mem.indexOf(u8, existing, "agx-explore-lead") != null or
        std.mem.indexOf(u8, existing, "agx Skills") != null)
    {
        return;
    }

    // Append agx section
    const new_content = try std.fmt.allocPrint(alloc, "{s}{s}", .{ existing, claude_md_section });

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    try writer.interface.writeAll(new_content);
    try writer.interface.flush();
    try stdout.print("Updated CLAUDE.md with agx instructions\n", .{});
}

fn createSkillFile(alloc: Allocator, repo_root: []const u8, name: []const u8, content: []const u8, stdout: *std.Io.Writer) !void {
    const dir_path = try std.fmt.allocPrint(alloc, "{s}/.claude/skills/{s}", .{ repo_root, name });
    const file_path = try std.fmt.allocPrint(alloc, "{s}/SKILL.md", .{dir_path});

    // Create directory structure
    try std.fs.cwd().makePath(dir_path);

    // Create file (exclusive — skip if exists)
    const file = std.fs.cwd().createFile(file_path, .{ .exclusive = true }) catch |err| {
        if (err == error.PathAlreadyExists) {
            return;
        }
        return err;
    };
    defer file.close();

    var buf: [8192]u8 = undefined;
    var writer = file.writer(&buf);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
    try stdout.print("Created .claude/skills/{s}/SKILL.md\n", .{name});
}
