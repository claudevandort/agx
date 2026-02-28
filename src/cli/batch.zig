const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const Ulid = agx.Ulid;
const CliContext = @import("cli_common.zig").CliContext;
const overlap = agx.batch_overlap;
const JsonWriter = agx.json_writer.JsonWriter;

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (args.len == 0) {
        try printUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    }

    const subcmd = args[0];
    const sub_args = args[1..];

    if (std.mem.eql(u8, subcmd, "create")) {
        try runCreate(alloc, sub_args, stdout, stderr);
    } else if (std.mem.eql(u8, subcmd, "status")) {
        try runStatus(alloc, sub_args, stdout, stderr);
    } else if (std.mem.eql(u8, subcmd, "merge")) {
        try runMerge(alloc, sub_args, stdout, stderr);
    } else {
        try stderr.print("agx batch: unknown subcommand '{s}'\n", .{subcmd});
        try printUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    }

    try stdout.flush();
}

fn printUsage(w: *std.Io.Writer) !void {
    try w.print(
        \\Usage: agx batch <subcommand> [options]
        \\
        \\Subcommands:
        \\  create --tasks "desc1" "desc2" ...   Create a batch with multiple tasks
        \\  status [--batch <id>]                Show batch and per-task status
        \\  merge [--batch <id>] [--dry-run]     Merge all completed tasks sequentially
        \\
        \\Create options:
        \\  --tasks "desc1" "desc2" ...   Task descriptions (required, consumes remaining args)
        \\  --policy semi|autonomous|manual  Conflict resolution policy (default: semi)
        \\  --base <ref>                  Base commit/branch (default: HEAD)
        \\
        \\Merge options:
        \\  --dry-run                     Print merge order without merging
        \\  --batch <id>                  Batch ID prefix (default: most recent active)
        \\
    , .{});
}

// ── create subcommand ──

fn runCreate(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var task_descs = std.ArrayList([]const u8).empty;
    var policy_str: ?[]const u8 = null;
    var base_ref: ?[]const u8 = null;
    var collecting_tasks = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--tasks")) {
            collecting_tasks = true;
        } else if (std.mem.eql(u8, args[i], "--policy")) {
            collecting_tasks = false;
            i += 1;
            if (i < args.len) policy_str = args[i];
        } else if (std.mem.eql(u8, args[i], "--base")) {
            collecting_tasks = false;
            i += 1;
            if (i < args.len) base_ref = args[i];
        } else if (collecting_tasks) {
            try task_descs.append(aa, args[i]);
        }
    }

    if (task_descs.items.len < 2) {
        try stderr.print("error: --tasks requires at least 2 task descriptions\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const merge_policy = if (policy_str) |ps|
        agx.batch.MergePolicy.fromStr(ps) catch {
            try stderr.print("error: invalid policy '{s}' (use: autonomous, semi, manual)\n", .{ps});
            try stderr.flush();
            std.process.exit(1);
        }
    else
        .semi;

    var ctx = CliContext.open(aa, stderr);
    defer ctx.deinit();

    // Resolve base
    const base_commit = if (base_ref) |ref|
        try ctx.git.resolveRef(ref)
    else
        try ctx.git.headCommit();

    const base_branch = ctx.git.currentBranch() catch try aa.dupe(u8, "HEAD");

    const now = std.time.milliTimestamp();
    const batch_id = Ulid.new();
    const batch_short = batch_id.short(6);

    // Build batch description from task list
    const batch_desc = try std.fmt.allocPrint(aa, "Batch of {d} tasks", .{task_descs.items.len});

    try ctx.store.insertBatch(.{
        .id = batch_id,
        .description = batch_desc,
        .base_commit = base_commit,
        .base_branch = base_branch,
        .status = .active,
        .merge_policy = merge_policy,
        .merge_order = null,
        .created_at = now,
        .updated_at = now,
    });

    try stdout.print("Batch {s}: {s}\n", .{ &batch_short, batch_desc });
    try stdout.print("Base: {s} ({s})\n", .{ base_branch, base_commit[0..@min(8, base_commit.len)] });
    try stdout.print("Policy: {s}\n\n", .{merge_policy.toStr()});

    // Create worktree base dir
    const worktree_base = try std.fmt.allocPrint(aa, "{s}/agx/worktrees/batch-{s}", .{ ctx.git_dir, &batch_short });
    std.fs.cwd().makePath(worktree_base) catch {};

    // Create tasks + explorations + sessions + worktrees
    for (task_descs.items, 0..) |desc, task_idx| {
        const task_id = Ulid.new();
        const task_short = task_id.short(6);
        const idx: u32 = @intCast(task_idx + 1);

        try ctx.store.insertTask(.{
            .id = task_id,
            .description = desc,
            .base_commit = base_commit,
            .base_branch = base_branch,
            .status = .active,
            .resolved_exploration_id = null,
            .batch_id = batch_id,
            .created_at = now,
            .updated_at = now,
        });

        // One exploration per task
        const exp_id = Ulid.new();
        const branch_name = try std.fmt.allocPrint(aa, "agx/batch-{s}/{d}", .{ &batch_short, idx });
        const worktree_path = try std.fmt.allocPrint(aa, "{s}/{d}", .{ worktree_base, idx });

        ctx.git.addWorktree(worktree_path, branch_name) catch |err| {
            try stderr.print("error: could not create worktree {d}: {s}\n", .{ idx, @errorName(err) });
            try stderr.flush();
            std.process.exit(1);
        };

        try ctx.store.insertExploration(.{
            .id = exp_id,
            .task_id = task_id,
            .index = 1,
            .worktree_path = worktree_path,
            .branch_name = branch_name,
            .status = .active,
            .approach = null,
            .summary = null,
            .created_at = now,
            .updated_at = now,
        });

        // Create session + .agx-session file
        const session_id = Ulid.new();
        try ctx.store.insertSession(.{
            .id = session_id,
            .exploration_id = exp_id,
            .agent_type = null,
            .model_version = null,
            .environment_fingerprint = null,
            .initial_prompt = desc,
            .exit_reason = null,
            .started_at = now,
            .ended_at = null,
        });

        const session_file_path = try std.fmt.allocPrint(aa, "{s}/.agx-session", .{worktree_path});
        const session_id_str = session_id.encode();
        const exp_id_str = exp_id.encode();
        const task_id_str = task_id.encode();

        const session_file = try std.fs.cwd().createFile(session_file_path, .{});
        defer session_file.close();

        var file_buf: [512]u8 = undefined;
        var file_writer = session_file.writer(&file_buf);
        try file_writer.interface.print("session_id={s}\nexploration_id={s}\ntask_id={s}\nindex=1\n", .{
            &session_id_str,
            &exp_id_str,
            &task_id_str,
        });
        try file_writer.interface.flush();

        try stdout.print("  [{d}] {s} — {s}\n", .{ idx, &task_short, desc });
        try stdout.print("       worktree: {s}\n", .{worktree_path});
        try stdout.print("       branch:   {s}\n", .{branch_name});
    }

    try stdout.print("\n{d} tasks created. Start agents in each worktree.\n", .{task_descs.items.len});
}

// ── status subcommand ──

fn runStatus(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var ctx = CliContext.open(aa, stderr);
    defer ctx.deinit();

    // Parse --batch <id> (TODO: support prefix lookup)
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--batch")) {
            i += 1; // skip value
        }
    }

    const batch = ctx.store.getActiveBatch() catch {
        try stderr.print("error: no active batch found\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    const batch_short = batch.id.short(6);
    try stdout.print("Batch {s}: {s}\n", .{ &batch_short, batch.description });
    try stdout.print("Status: {s}  Policy: {s}\n", .{ batch.status.toStr(), batch.merge_policy.toStr() });
    try stdout.print("Base: {s} ({s})\n\n", .{ batch.base_branch, batch.base_commit[0..@min(8, batch.base_commit.len)] });

    // Get tasks
    var task_buf: [64]agx.Task = undefined;
    const tasks = try ctx.store.getTasksByBatch(batch.id, &task_buf);

    if (tasks.len == 0) {
        try stdout.print("No tasks in this batch.\n", .{});
        return;
    }

    try stdout.print("{s:<6} {s:<10} {s:<28} {s}\n", .{ "INDEX", "STATUS", "TASK ID", "DESCRIPTION" });
    try stdout.print("{s:<6} {s:<10} {s:<28} {s}\n", .{ "-----", "------", "-------", "-----------" });

    for (tasks, 0..) |t, idx| {
        const task_short = t.id.short(6);
        const task_enc = t.id.encode();

        // Get exploration info
        var exp_buf: [4]agx.Exploration = undefined;
        const exps = ctx.store.getExplorationsByTask(t.id, &exp_buf) catch &[_]agx.Exploration{};

        const approach: []const u8 = if (exps.len > 0 and exps[0].approach != null) exps[0].approach.? else "-";
        _ = approach;

        const max_desc: usize = 40;
        const desc_display = if (t.description.len > max_desc) t.description[0..max_desc] else t.description;

        try stdout.print("[{d:<4}] {s:<10} {s}  {s}\n", .{
            idx + 1,
            t.status.toStr(),
            &task_enc,
            desc_display,
        });

        _ = task_short;
    }
}

// ── merge subcommand ──

fn runMerge(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var dry_run = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, args[i], "--batch")) {
            i += 1; // skip value (TODO: support --batch prefix lookup)
        }
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var ctx = CliContext.open(aa, stderr);
    defer ctx.deinit();

    const batch = ctx.store.getActiveBatch() catch {
        try stderr.print("error: no active batch found\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    // Get tasks
    var task_buf: [64]agx.Task = undefined;
    const tasks = try ctx.store.getTasksByBatch(batch.id, &task_buf);

    if (tasks.len == 0) {
        try stderr.print("error: no tasks in batch\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    // Verify all tasks have a done exploration
    for (tasks, 0..) |t, idx| {
        var exp_buf: [4]agx.Exploration = undefined;
        const exps = try ctx.store.getExplorationsByTask(t.id, &exp_buf);
        var has_done = false;
        for (exps) |e| {
            if (e.status == .done or e.status == .kept) {
                has_done = true;
                break;
            }
        }
        if (!has_done) {
            try stderr.print("error: task [{d}] '{s}' has no completed exploration\n", .{ idx + 1, t.description });
            try stderr.flush();
            std.process.exit(1);
        }
    }

    // Compute file overlap and merge order
    var file_sets = try aa.alloc(overlap.FileSet, tasks.len);
    for (tasks, 0..) |t, idx| {
        // Get the branch for this task's exploration
        var exp_buf: [4]agx.Exploration = undefined;
        const exps = try ctx.store.getExplorationsByTask(t.id, &exp_buf);
        const branch = exps[0].branch_name;

        // Get changed files
        const numstat = ctx.git.diffNumstat(batch.base_commit, branch) catch "";
        const files = try overlap.getChangedFiles(aa, numstat);

        file_sets[idx] = .{
            .task_index = idx,
            .files = files,
        };
    }

    const merge_order = try overlap.computeMergeOrder(aa, file_sets);

    // Build merge order JSON and store it
    var order_json = std.ArrayList(u8).empty;
    try order_json.append(aa, '[');
    for (merge_order, 0..) |task_idx, oi| {
        if (oi > 0) try order_json.append(aa, ',');
        const task_enc = tasks[task_idx].id.encode();
        try order_json.append(aa, '"');
        try order_json.appendSlice(aa, &task_enc);
        try order_json.append(aa, '"');
    }
    try order_json.append(aa, ']');
    try ctx.store.updateBatchMergeOrder(batch.id, order_json.items);

    // Print merge plan
    try stdout.print("Merge order ({d} tasks):\n", .{merge_order.len});
    for (merge_order, 0..) |task_idx, step| {
        const t = tasks[task_idx];
        const fs = file_sets[task_idx];
        try stdout.print("  {d}. [{d}] {s} ({d} files changed)\n", .{
            step + 1,
            task_idx + 1,
            t.description,
            fs.files.len,
        });
    }

    // Show overlap matrix
    try stdout.print("\nFile overlap:\n", .{});
    var has_overlap = false;
    for (0..tasks.len) |a| {
        for (a + 1..tasks.len) |b| {
            var shared: u32 = 0;
            for (file_sets[a].files) |fa| {
                for (file_sets[b].files) |fb| {
                    if (std.mem.eql(u8, fa, fb)) {
                        shared += 1;
                        break;
                    }
                }
            }
            if (shared > 0) {
                has_overlap = true;
                try stdout.print("  [{d}] <-> [{d}]: {d} shared file(s)\n", .{ a + 1, b + 1, shared });
            }
        }
    }
    if (!has_overlap) {
        try stdout.print("  (none — all tasks touch disjoint files)\n", .{});
    }

    if (dry_run) {
        try stdout.print("\n--dry-run: no merges performed.\n", .{});
        return;
    }

    // Execute sequential merge
    try ctx.store.updateBatchStatus(batch.id, .merging);

    // Checkout base branch
    ctx.git.checkout(batch.base_branch) catch {
        try stderr.print("error: could not checkout base branch '{s}'\n", .{batch.base_branch});
        try stderr.flush();
        std.process.exit(1);
    };

    try stdout.print("\nMerging into {s}...\n", .{batch.base_branch});

    var all_clean = true;
    for (merge_order, 0..) |task_idx, step| {
        const t = tasks[task_idx];
        var exp_buf2: [4]agx.Exploration = undefined;
        const exps = try ctx.store.getExplorationsByTask(t.id, &exp_buf2);
        const branch = exps[0].branch_name;

        try stdout.print("\n  Step {d}/{d}: merging [{d}] {s}...\n", .{ step + 1, merge_order.len, task_idx + 1, t.description });

        const merge_result = ctx.git.mergeNoCommit(branch) catch {
            try stderr.print("error: merge failed for branch '{s}'\n", .{branch});
            all_clean = false;
            break;
        };

        switch (merge_result) {
            .clean => {
                // Commit with trailers
                const batch_enc = batch.id.encode();
                const task_enc = t.id.encode();
                const commit_msg = try std.fmt.allocPrint(aa, "agx batch merge: {s}\n\nAGX-Batch: {s}\nAGX-Task: {s}", .{
                    t.description,
                    &batch_enc,
                    &task_enc,
                });
                ctx.git.mergeCommit(commit_msg) catch {
                    try stderr.print("error: could not commit merge for task [{d}]\n", .{task_idx + 1});
                    all_clean = false;
                    break;
                };
                try stdout.print("    Clean merge — committed.\n", .{});
            },
            .conflict => {
                const conflicted = ctx.git.conflictedFiles() catch "unknown";
                try stdout.print("    CONFLICT in: {s}\n", .{conflicted});

                // Behavior depends on merge policy
                switch (batch.merge_policy) {
                    .autonomous => {
                        try stdout.print("    Policy: autonomous — agent should resolve conflicts.\n", .{});
                        try stdout.print("    Aborting merge. Resolve conflicts and run 'git commit' to continue.\n", .{});
                    },
                    .semi => {
                        try stdout.print("    Policy: semi — review conflicts and resolve.\n", .{});
                        try stdout.print("    Aborting merge. Resolve conflicts and run 'git commit' to continue.\n", .{});
                    },
                    .manual => {
                        try stdout.print("    Policy: manual — user must resolve all conflicts.\n", .{});
                        try stdout.print("    Aborting merge. Resolve conflicts and run 'git commit' to continue.\n", .{});
                    },
                }
                all_clean = false;
                // Don't abort — leave the conflict state for the user/agent to resolve
                break;
            },
        }
    }

    if (all_clean) {
        try ctx.store.updateBatchStatus(batch.id, .completed);
        try stdout.print("\nAll {d} tasks merged successfully. Batch completed.\n", .{merge_order.len});
    } else {
        try ctx.store.updateBatchStatus(batch.id, .failed);
        try stdout.print("\nBatch merge stopped due to conflicts. Resolve and retry.\n", .{});
    }

}
