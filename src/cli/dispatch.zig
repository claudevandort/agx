const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");
const Ulid = agx.Ulid;
const CliContext = @import("cli_common.zig").CliContext;
const overlap = agx.dispatch_overlap;
const JsonWriter = agx.json_writer.JsonWriter;

pub fn run(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (args.len == 0) {
        try printUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        try printUsage(stdout);
        try stdout.flush();
        return;
    }

    const subcmd = args[0];
    const sub_args = args[1..];

    if (std.mem.eql(u8, subcmd, "create")) {
        try runCreate(alloc, sub_args, stdout, stderr);
    } else if (std.mem.eql(u8, subcmd, "status")) {
        try runStatus(alloc, sub_args, stdout, stderr);
    } else if (std.mem.eql(u8, subcmd, "merge")) {
        try runMerge(alloc, sub_args, stdout, stderr);
    } else if (std.mem.eql(u8, subcmd, "cancel")) {
        try runCancel(alloc, sub_args, stdout, stderr);
    } else {
        try stderr.print("agx dispatch: unknown subcommand '{s}'\n", .{subcmd});
        try printUsage(stderr);
        try stderr.flush();
        std.process.exit(1);
    }

    try stdout.flush();
}

fn printUsage(w: *std.Io.Writer) !void {
    try w.print(
        \\Usage: agx dispatch <subcommand> [options]
        \\
        \\Subcommands:
        \\  create --goals "desc1" "desc2" ...  Create a dispatch with multiple goals
        \\  status [--dispatch <id>]             Show dispatch and per-goal status
        \\  merge [--dispatch <id>] [--dry-run]  Merge completed goals sequentially
        \\        [--continue]
        \\  cancel [--dispatch <id>]             Cancel an active dispatch
        \\
        \\Create options:
        \\  --goals "desc1" "desc2" ...  Goal descriptions (required, consumes remaining args)
        \\  --policy semi|autonomous|manual  Conflict resolution policy (default: semi)
        \\  --base <ref>                  Base commit/branch (default: HEAD)
        \\
        \\Merge options:
        \\  --dry-run                     Print merge order without merging
        \\  --dispatch <id>               Dispatch ID prefix (default: most recent active)
        \\  --continue                    Resume after resolving merge conflicts
        \\
    , .{});
}

// ── create subcommand ──

fn runCreate(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var goal_descs = std.ArrayList([]const u8).empty;
    var policy_str: ?[]const u8 = null;
    var base_ref: ?[]const u8 = null;
    var collecting_goals = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--goals")) {
            collecting_goals = true;
        } else if (std.mem.eql(u8, args[i], "--policy")) {
            collecting_goals = false;
            i += 1;
            if (i < args.len) policy_str = args[i];
        } else if (std.mem.eql(u8, args[i], "--base")) {
            collecting_goals = false;
            i += 1;
            if (i < args.len) base_ref = args[i];
        } else if (collecting_goals) {
            try goal_descs.append(aa, args[i]);
        }
    }

    if (goal_descs.items.len < 2) {
        try stderr.print("error: --goals requires at least 2 goal descriptions\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const merge_policy = if (policy_str) |ps|
        agx.dispatch.MergePolicy.fromStr(ps) catch {
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
    const dispatch_id = Ulid.new();
    const dispatch_short = dispatch_id.short(6);

    // Build dispatch description from goal list
    const dispatch_desc = try std.fmt.allocPrint(aa, "Dispatch of {d} goals", .{goal_descs.items.len});

    try ctx.store.insertDispatch(.{
        .id = dispatch_id,
        .description = dispatch_desc,
        .base_commit = base_commit,
        .base_branch = base_branch,
        .status = .active,
        .merge_policy = merge_policy,
        .merge_order = null,
        .merge_progress = 0,
        .created_at = now,
        .updated_at = now,
    });

    try stdout.print("Dispatch {s}: {s}\n", .{ &dispatch_short, dispatch_desc });
    try stdout.print("Base: {s} ({s})\n", .{ base_branch, base_commit[0..@min(8, base_commit.len)] });
    try stdout.print("Policy: {s}\n\n", .{merge_policy.toStr()});

    // Create worktree base dir
    const worktree_base = try std.fmt.allocPrint(aa, "{s}/agx/worktrees/dispatch-{s}", .{ ctx.git_dir, &dispatch_short });
    std.fs.cwd().makePath(worktree_base) catch {};

    // Create goals + tasks + sessions + worktrees
    for (goal_descs.items, 0..) |desc, goal_idx| {
        const goal_id = Ulid.new();
        const goal_short = goal_id.short(6);
        const idx: u32 = @intCast(goal_idx + 1);

        try ctx.store.insertGoal(.{
            .id = goal_id,
            .description = desc,
            .base_commit = base_commit,
            .base_branch = base_branch,
            .status = .active,
            .resolved_task_id = null,
            .dispatch_id = dispatch_id,
            .created_at = now,
            .updated_at = now,
        });

        // One task per goal
        const task_id = Ulid.new();
        const branch_name = try std.fmt.allocPrint(aa, "agx/dispatch-{s}/{d}", .{ &dispatch_short, idx });
        const worktree_path = try std.fmt.allocPrint(aa, "{s}/{d}", .{ worktree_base, idx });

        ctx.git.addWorktree(worktree_path, branch_name) catch |err| {
            try stderr.print("error: could not create worktree {d}: {s}\n", .{ idx, @errorName(err) });
            try stderr.flush();
            std.process.exit(1);
        };

        try ctx.store.insertTask(.{
            .id = task_id,
            .goal_id = goal_id,
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
            .exploration_id = task_id,
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
        const task_id_str = task_id.encode();
        const goal_id_str = goal_id.encode();

        const session_file = try std.fs.cwd().createFile(session_file_path, .{});
        defer session_file.close();

        var file_buf: [512]u8 = undefined;
        var file_writer = session_file.writer(&file_buf);
        try file_writer.interface.print("session_id={s}\ntask_id={s}\ngoal_id={s}\nindex=1\n", .{
            &session_id_str,
            &task_id_str,
            &goal_id_str,
        });
        try file_writer.interface.flush();

        try stdout.print("  [{d}] {s} — {s}\n", .{ idx, &goal_short, desc });
        try stdout.print("       worktree: {s}\n", .{worktree_path});
        try stdout.print("       branch:   {s}\n", .{branch_name});
    }

    try stdout.print("\n{d} goals created. Start agents in each worktree.\n", .{goal_descs.items.len});
}

// ── status subcommand ──

fn runStatus(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var ctx = CliContext.open(aa, stderr);
    defer ctx.deinit();

    // Parse --dispatch <id>
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dispatch")) {
            i += 1; // skip value
        }
    }

    const d = ctx.store.getActiveDispatch() catch {
        try stderr.print("error: no active dispatch found\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    const dispatch_short = d.id.short(6);
    try stdout.print("Dispatch {s}: {s}\n", .{ &dispatch_short, d.description });
    try stdout.print("Status: {s}  Policy: {s}\n", .{ d.status.toStr(), d.merge_policy.toStr() });
    try stdout.print("Base: {s} ({s})\n\n", .{ d.base_branch, d.base_commit[0..@min(8, d.base_commit.len)] });

    // Get goals
    var goal_buf: [64]agx.Goal = undefined;
    const goals = try ctx.store.getGoalsByDispatch(d.id, &goal_buf);

    if (goals.len == 0) {
        try stdout.print("No goals in this dispatch.\n", .{});
        return;
    }

    try stdout.print("{s:<6} {s:<10} {s:<28} {s}\n", .{ "INDEX", "STATUS", "GOAL ID", "DESCRIPTION" });
    try stdout.print("{s:<6} {s:<10} {s:<28} {s}\n", .{ "-----", "------", "-------", "-----------" });

    for (goals, 0..) |g, idx| {
        const goal_enc = g.id.encode();

        // Get task info
        var task_buf: [4]agx.Task = undefined;
        const tasks = ctx.store.getTasksByGoal(g.id, &task_buf) catch &[_]agx.Task{};

        const approach: []const u8 = if (tasks.len > 0 and tasks[0].approach != null) tasks[0].approach.? else "-";
        _ = approach;

        const max_desc: usize = 40;
        const desc_display = if (g.description.len > max_desc) g.description[0..max_desc] else g.description;

        try stdout.print("[{d:<4}] {s:<10} {s}  {s}\n", .{
            idx + 1,
            g.status.toStr(),
            &goal_enc,
            desc_display,
        });
    }
}

// ── merge subcommand ──

fn runMerge(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var dry_run = false;
    var continue_merge = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, args[i], "--continue")) {
            continue_merge = true;
        } else if (std.mem.eql(u8, args[i], "--dispatch")) {
            i += 1; // skip value
        }
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var ctx = CliContext.open(aa, stderr);
    defer ctx.deinit();

    const d = ctx.store.getActiveDispatch() catch {
        try stderr.print("error: no active dispatch found\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    // If dispatch is in conflict state, require --continue
    if (d.status == .conflict and !continue_merge) {
        try stderr.print("error: dispatch has unresolved merge conflicts\n", .{});
        try stderr.print("Resolve the conflicts, then run: agx dispatch merge --continue\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    // Get goals
    var goal_buf: [64]agx.Goal = undefined;
    const goals = try ctx.store.getGoalsByDispatch(d.id, &goal_buf);

    if (goals.len == 0) {
        try stderr.print("error: no goals in dispatch\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    // Compute file overlap and merge order
    var file_sets = try aa.alloc(overlap.FileSet, goals.len);
    for (goals, 0..) |g, idx| {
        var task_buf: [4]agx.Task = undefined;
        const tasks = try ctx.store.getTasksByGoal(g.id, &task_buf);
        const branch = tasks[0].branch_name;
        const numstat = ctx.git.diffNumstat(d.base_commit, branch) catch "";
        const files = try overlap.getChangedFiles(aa, numstat);
        file_sets[idx] = .{
            .goal_index = idx,
            .files = files,
        };
    }

    const merge_order = try overlap.computeMergeOrder(aa, file_sets);

    // Store merge order if not already stored
    if (d.merge_order == null) {
        var order_json = std.ArrayList(u8).empty;
        try order_json.append(aa, '[');
        for (merge_order, 0..) |goal_idx, oi| {
            if (oi > 0) try order_json.append(aa, ',');
            const goal_enc = goals[goal_idx].id.encode();
            try order_json.append(aa, '"');
            try order_json.appendSlice(aa, &goal_enc);
            try order_json.append(aa, '"');
        }
        try order_json.append(aa, ']');
        try ctx.store.updateDispatchMergeOrder(d.id, order_json.items);
    }

    // Determine starting step
    var start_step: usize = d.merge_progress;

    // Handle --continue: commit the resolved conflict, then advance
    if (continue_merge) {
        if (d.status != .conflict) {
            try stderr.print("error: --continue used but dispatch is not in conflict state\n", .{});
            try stderr.flush();
            std.process.exit(1);
        }

        // Check if there are still unresolved conflicts
        const unmerged = ctx.git.conflictedFiles() catch "";
        if (unmerged.len > 0) {
            try stderr.print("error: there are still unresolved conflicts:\n{s}\n", .{unmerged});
            try stderr.print("Resolve all conflicts, stage with 'git add', then run: agx dispatch merge --continue\n", .{});
            try stderr.flush();
            std.process.exit(1);
        }

        // Commit the resolved merge
        const conflict_goal_idx = merge_order[start_step];
        const conflict_goal = goals[conflict_goal_idx];
        const dispatch_enc = d.id.encode();
        const goal_enc = conflict_goal.id.encode();
        const commit_msg = try std.fmt.allocPrint(aa, "agx dispatch merge: {s}\n\nAGX-Dispatch: {s}\nAGX-Goal: {s}", .{
            conflict_goal.description,
            &dispatch_enc,
            &goal_enc,
        });
        ctx.git.mergeCommit(commit_msg) catch {
            try stderr.print("error: could not commit resolved merge for goal [{d}]\n", .{conflict_goal_idx + 1});
            try stderr.print("Stage your resolved files with 'git add' first.\n", .{});
            try stderr.flush();
            std.process.exit(1);
        };

        start_step += 1;
        try ctx.store.updateDispatchMergeProgress(d.id, @intCast(start_step));
        try ctx.store.updateDispatchStatus(d.id, .merging);
        try stdout.print("Conflict resolved — committed step {d}/{d}.\n", .{ start_step, merge_order.len });

        if (start_step >= merge_order.len) {
            try ctx.store.updateDispatchStatus(d.id, .completed);
            try stdout.print("\nAll {d} goals merged successfully. Dispatch completed.\n", .{merge_order.len});
            return;
        }
    } else {
        // Verify all goals have a done task (only on fresh merge, not --continue)
        for (goals, 0..) |g, idx| {
            var task_buf: [4]agx.Task = undefined;
            const tasks = try ctx.store.getTasksByGoal(g.id, &task_buf);
            var has_done = false;
            for (tasks) |t| {
                if (t.status == .done or t.status == .kept) {
                    has_done = true;
                    break;
                }
            }
            if (!has_done) {
                try stderr.print("error: goal [{d}] '{s}' has no completed task\n", .{ idx + 1, g.description });
                try stderr.flush();
                std.process.exit(1);
            }
        }
    }

    // Print merge plan
    try stdout.print("\nMerge order ({d} goals):\n", .{merge_order.len});
    for (merge_order, 0..) |goal_idx, step| {
        const g = goals[goal_idx];
        const fs = file_sets[goal_idx];
        const status_marker: []const u8 = if (step < start_step) " [done]" else "";
        try stdout.print("  {d}. [{d}] {s} ({d} files changed){s}\n", .{
            step + 1,
            goal_idx + 1,
            g.description,
            fs.files.len,
            status_marker,
        });
    }

    if (start_step > 0 and !continue_merge) {
        try stdout.print("\nResuming from step {d} ({d} already merged).\n", .{ start_step + 1, start_step });
    }

    // Show overlap matrix
    try stdout.print("\nFile overlap:\n", .{});
    var has_overlap = false;
    for (0..goals.len) |a| {
        for (a + 1..goals.len) |b| {
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
        try stdout.print("  (none — all goals touch disjoint files)\n", .{});
    }

    if (dry_run) {
        try stdout.print("\n--dry-run: no merges performed.\n", .{});
        return;
    }

    // Execute sequential merge starting from progress point
    try ctx.store.updateDispatchStatus(d.id, .merging);

    // Checkout base branch (only if starting fresh — if continuing, we're already on it)
    if (!continue_merge) {
        ctx.git.checkout(d.base_branch) catch {
            try stderr.print("error: could not checkout base branch '{s}'\n", .{d.base_branch});
            try stderr.flush();
            std.process.exit(1);
        };
    }

    try stdout.print("\nMerging into {s}...\n", .{d.base_branch});

    for (merge_order[start_step..], start_step..) |goal_idx, step| {
        const g = goals[goal_idx];
        var task_buf2: [4]agx.Task = undefined;
        const tasks = try ctx.store.getTasksByGoal(g.id, &task_buf2);
        const branch = tasks[0].branch_name;

        try stdout.print("\n  Step {d}/{d}: merging [{d}] {s}...\n", .{ step + 1, merge_order.len, goal_idx + 1, g.description });

        const merge_result = ctx.git.mergeNoCommit(branch) catch {
            try stderr.print("error: merge failed for branch '{s}'\n", .{branch});
            try ctx.store.updateDispatchStatus(d.id, .failed);
            try stdout.print("\nDispatch merge failed (git error). Fix and retry with: agx dispatch merge\n", .{});
            return;
        };

        switch (merge_result) {
            .clean => {
                const dispatch_enc = d.id.encode();
                const goal_enc = g.id.encode();
                const commit_msg = try std.fmt.allocPrint(aa, "agx dispatch merge: {s}\n\nAGX-Dispatch: {s}\nAGX-Goal: {s}", .{
                    g.description,
                    &dispatch_enc,
                    &goal_enc,
                });
                ctx.git.mergeCommit(commit_msg) catch {
                    try stderr.print("error: could not commit merge for goal [{d}]\n", .{goal_idx + 1});
                    try ctx.store.updateDispatchStatus(d.id, .failed);
                    return;
                };
                const progress: u32 = @intCast(step + 1);
                try ctx.store.updateDispatchMergeProgress(d.id, progress);
                try stdout.print("    Clean merge — committed. ({d}/{d})\n", .{ progress, merge_order.len });
            },
            .conflict => {
                const conflicted = ctx.git.conflictedFiles() catch "unknown";
                try stdout.print("    CONFLICT in: {s}\n", .{conflicted});
                try stdout.print("    Resolve conflicts, stage with 'git add', then run:\n", .{});
                try stdout.print("      agx dispatch merge --continue\n", .{});

                // Set status to conflict — dispatch stays findable
                try ctx.store.updateDispatchStatus(d.id, .conflict);
                try stdout.print("\nDispatch merge paused at step {d}/{d}.\n", .{ step + 1, merge_order.len });
                return;
            },
        }
    }

    try ctx.store.updateDispatchStatus(d.id, .completed);
    try stdout.print("\nAll {d} goals merged successfully. Dispatch completed.\n", .{merge_order.len});
}

// ── cancel subcommand ──

fn runCancel(alloc: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    _ = args; // --dispatch prefix lookup not yet implemented

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var ctx = CliContext.open(aa, stderr);
    defer ctx.deinit();

    const d = ctx.store.getActiveDispatch() catch {
        try stderr.print("error: no active dispatch found\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    const dispatch_short = d.id.short(6);
    const prev_status = d.status;

    // Abort any in-progress git merge if the dispatch was in conflict or merging state
    if (prev_status == .conflict or prev_status == .merging) {
        ctx.git.mergeAbort() catch {};
    }

    // Mark dispatch as abandoned
    try ctx.store.updateDispatchStatus(d.id, .abandoned);

    // Report what was cancelled
    try stdout.print("Cancelled dispatch {s}: {s}\n", .{ &dispatch_short, d.description });
    try stdout.print("Previous status: {s}\n", .{prev_status.toStr()});

    if (prev_status == .conflict) {
        try stdout.print("Aborted in-progress merge (was paused on conflict).\n", .{});
    } else if (prev_status == .merging) {
        try stdout.print("Aborted in-progress merge.\n", .{});
    }

    // Show goal summary
    var goal_buf: [64]agx.Goal = undefined;
    const goals = try ctx.store.getGoalsByDispatch(d.id, &goal_buf);

    if (goals.len > 0) {
        var done_count: u32 = 0;
        var active_count: u32 = 0;
        for (goals) |g| {
            if (g.status == .resolved) done_count += 1;
            if (g.status == .active) active_count += 1;
        }
        try stdout.print("\nGoals: {d} total, {d} completed, {d} active\n", .{ goals.len, done_count, active_count });
        if (d.merge_progress > 0) {
            try stdout.print("Merge progress: {d}/{d} goals had been merged\n", .{ d.merge_progress, goals.len });
        }
    }

    try stdout.print("\nDispatch is now abandoned. Run 'agx exploration clean' to remove worktrees and branches.\n", .{});
}
