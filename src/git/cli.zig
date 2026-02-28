const std = @import("std");
const Allocator = std.mem.Allocator;
const Child = std.process.Child;

/// Result of a git command execution.
pub const GitResult = struct {
    stdout: []u8,
    stderr: []u8,
    success: bool,

    pub fn deinit(self: *const GitResult, alloc: Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
    }
};

/// Git CLI abstraction. All git operations go through this.
/// Wraps std.process.Child to shell out to the git binary.
pub const GitCli = struct {
    alloc: Allocator,
    repo_path: ?[]const u8, // working directory for git commands

    pub fn init(alloc: Allocator, repo_path: ?[]const u8) GitCli {
        return .{ .alloc = alloc, .repo_path = repo_path };
    }

    /// Run an arbitrary git command and return the result.
    pub fn run(self: *const GitCli, args: []const []const u8) !GitResult {
        // Build argv: git [-C path] <args...>
        const prefix_len: usize = if (self.repo_path != null) 3 else 1;
        const argv = try self.alloc.alloc([]const u8, prefix_len + args.len);
        defer self.alloc.free(argv);

        argv[0] = "git";
        if (self.repo_path) |path| {
            argv[1] = "-C";
            argv[2] = path;
        }
        for (args, 0..) |arg, i| {
            argv[prefix_len + i] = arg;
        }

        const result = try Child.run(.{
            .allocator = self.alloc,
            .argv = argv,
            .max_output_bytes = 1024 * 1024, // 1MB
        });

        const success = switch (result.term) {
            .Exited => |code| code == 0,
            else => false,
        };

        return .{
            .stdout = result.stdout,
            .stderr = result.stderr,
            .success = success,
        };
    }

    /// Run a git command, return error if it fails.
    /// On failure, logs the stderr output before returning the error.
    pub fn runChecked(self: *const GitCli, args: []const []const u8) !GitResult {
        const result = try self.run(args);
        if (!result.success) {
            if (result.stderr.len > 0) {
                const trimmed = std.mem.trimRight(u8, result.stderr, "\n\r ");
                if (trimmed.len > 0) {
                    std.log.err("git: {s}", .{trimmed});
                }
            }
            result.deinit(self.alloc);
            return error.GitCommandFailed;
        }
        return result;
    }

    /// Run a checked command and return trimmed stdout, freeing stderr.
    fn runTrimmed(self: *const GitCli, args: []const []const u8) ![]u8 {
        const result = try self.runChecked(args);
        self.alloc.free(result.stderr);
        const trimmed = std.mem.trimRight(u8, result.stdout, "\n\r ");
        if (trimmed.len < result.stdout.len) {
            const out = try self.alloc.dupe(u8, trimmed);
            self.alloc.free(result.stdout);
            return out;
        }
        return result.stdout;
    }

    // ── Repository queries ──

    pub fn repoRoot(self: *const GitCli) ![]u8 {
        return self.runTrimmed(&.{ "rev-parse", "--show-toplevel" });
    }

    pub fn gitDir(self: *const GitCli) ![]u8 {
        return self.runTrimmed(&.{ "rev-parse", "--git-dir" });
    }

    /// Get the common git dir (shared across worktrees).
    pub fn gitCommonDir(self: *const GitCli) ![]u8 {
        return self.runTrimmed(&.{ "rev-parse", "--git-common-dir" });
    }

    pub fn headCommit(self: *const GitCli) ![]u8 {
        return self.runTrimmed(&.{ "rev-parse", "HEAD" });
    }

    pub fn currentBranch(self: *const GitCli) ![]u8 {
        return self.runTrimmed(&.{ "rev-parse", "--abbrev-ref", "HEAD" });
    }

    pub fn resolveRef(self: *const GitCli, ref: []const u8) ![]u8 {
        return self.runTrimmed(&.{ "rev-parse", ref });
    }

    // ── Branch operations ──

    pub fn createBranch(self: *const GitCli, name: []const u8, base: []const u8) !void {
        const r = try self.runChecked(&.{ "branch", name, base });
        r.deinit(self.alloc);
    }

    pub fn deleteBranch(self: *const GitCli, name: []const u8) !void {
        const r = try self.runChecked(&.{ "branch", "-D", name });
        r.deinit(self.alloc);
    }

    // ── Worktree operations ──

    /// Add a new worktree at `path`, creating branch `branch`.
    pub fn addWorktree(self: *const GitCli, path: []const u8, branch: []const u8) !void {
        const r = try self.runChecked(&.{ "worktree", "add", path, "-b", branch });
        r.deinit(self.alloc);
    }

    /// Add a worktree at `path` on an existing branch.
    pub fn addWorktreeExisting(self: *const GitCli, path: []const u8, branch: []const u8) !void {
        const r = try self.runChecked(&.{ "worktree", "add", path, branch });
        r.deinit(self.alloc);
    }

    /// Remove a worktree.
    pub fn removeWorktree(self: *const GitCli, path: []const u8) !void {
        const r = try self.runChecked(&.{ "worktree", "remove", path, "--force" });
        r.deinit(self.alloc);
    }

    /// List worktrees (raw porcelain output).
    pub fn listWorktrees(self: *const GitCli) ![]u8 {
        const result = try self.runChecked(&.{ "worktree", "list", "--porcelain" });
        self.alloc.free(result.stderr);
        return result.stdout;
    }

    // ── Merge / Rebase / Cherry-pick ──

    pub const MergeStrategy = enum {
        merge,
        rebase,
        squash,
        cherry_pick,
    };

    pub fn mergeBranch(self: *const GitCli, branch: []const u8, strategy: MergeStrategy) !void {
        switch (strategy) {
            .merge => {
                const r = try self.runChecked(&.{ "merge", branch, "--no-edit" });
                r.deinit(self.alloc);
            },
            .rebase => {
                const r = try self.runChecked(&.{ "rebase", branch });
                r.deinit(self.alloc);
            },
            .squash => {
                const r1 = try self.runChecked(&.{ "merge", "--squash", branch });
                r1.deinit(self.alloc);
                const r2 = try self.runChecked(&.{ "commit", "--no-edit" });
                r2.deinit(self.alloc);
            },
            .cherry_pick => {
                const range = try std.fmt.allocPrint(self.alloc, "HEAD..{s}", .{branch});
                defer self.alloc.free(range);
                const r = try self.runChecked(&.{ "cherry-pick", range });
                r.deinit(self.alloc);
            },
        }
    }

    // ── Conflict-aware merge primitives ──

    pub const MergeResult = enum { clean, conflict };

    /// Merge a branch without committing or fast-forwarding.
    /// Returns .clean on success, .conflict if there are conflicts.
    pub fn mergeNoCommit(self: *const GitCli, branch: []const u8) !MergeResult {
        const result = try self.run(&.{ "merge", "--no-commit", "--no-ff", branch });
        defer result.deinit(self.alloc);
        if (result.success) return .clean;
        // Exit code 1 with conflicts is expected; other failures are errors
        if (result.stderr.len > 0) {
            const trimmed = std.mem.trimRight(u8, result.stderr, "\n\r ");
            // "Automatic merge failed" indicates conflicts, not a fatal error
            if (std.mem.indexOf(u8, trimmed, "CONFLICT") != null or
                std.mem.indexOf(u8, trimmed, "Automatic merge failed") != null)
            {
                return .conflict;
            }
        }
        return .conflict;
    }

    /// Abort an in-progress merge.
    pub fn mergeAbort(self: *const GitCli) !void {
        const r = try self.runChecked(&.{ "merge", "--abort" });
        r.deinit(self.alloc);
    }

    /// Commit the current staged merge result.
    pub fn mergeCommit(self: *const GitCli, message: []const u8) !void {
        const r = try self.runChecked(&.{ "commit", "-m", message });
        r.deinit(self.alloc);
    }

    /// Get the list of conflicted file paths (newline-separated).
    pub fn conflictedFiles(self: *const GitCli) ![]u8 {
        return self.runTrimmed(&.{ "diff", "--name-only", "--diff-filter=U" });
    }

    // ── Diff / Stats ──

    pub fn diffNumstat(self: *const GitCli, base: []const u8, head: []const u8) ![]u8 {
        const result = try self.runChecked(&.{ "diff", "--numstat", base, head });
        self.alloc.free(result.stderr);
        return result.stdout;
    }

    pub fn diffFilter(self: *const GitCli, base: []const u8, head: []const u8, filter: []const u8) ![]u8 {
        const result = try self.runChecked(&.{ "diff", "--name-only", "--diff-filter", filter, base, head });
        self.alloc.free(result.stderr);
        return result.stdout;
    }

    pub fn commitCount(self: *const GitCli, base: []const u8, head: []const u8) !u32 {
        const range = try std.fmt.allocPrint(self.alloc, "{s}..{s}", .{ base, head });
        defer self.alloc.free(range);
        const result = try self.runChecked(&.{ "rev-list", "--count", range });
        defer result.deinit(self.alloc);
        const trimmed = std.mem.trimRight(u8, result.stdout, "\n\r ");
        return std.fmt.parseInt(u32, trimmed, 10) catch 0;
    }

    /// Three-way diff: show changes from base to head1 alongside base to head2.
    /// Uses merge-base to compute the common ancestor, then diffs both heads.
    pub fn diffThreeWay(self: *const GitCli, base: []const u8, head1: []const u8, head2: []const u8) ![]u8 {
        // Compute merge-base between the two heads rooted at base
        const merge_base = self.runTrimmed(&.{ "merge-base", base, head1 }) catch base;
        const should_free_merge_base = !std.mem.eql(u8, merge_base, base);

        // Diff head1 vs head2 relative to their common ancestor
        // Using diff with ... notation via merge-base
        const range = try std.fmt.allocPrint(self.alloc, "{s}...{s}", .{ head1, head2 });
        defer self.alloc.free(range);
        if (should_free_merge_base) self.alloc.free(merge_base);

        const result = try self.runChecked(&.{ "diff", range });
        self.alloc.free(result.stderr);
        return result.stdout;
    }

    // ── Commit trailers ──

    /// Amend the last commit to add trailers.
    pub fn addTrailers(self: *const GitCli, trailers: []const [2][]const u8) !void {
        // Get current commit message
        const msg_result = try self.runChecked(&.{ "log", "-1", "--format=%B" });
        defer msg_result.deinit(self.alloc);

        const msg_trimmed = std.mem.trimRight(u8, msg_result.stdout, "\n\r ");

        // Build new message with trailers appended
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);

        try buf.appendSlice(self.alloc, msg_trimmed);
        try buf.appendSlice(self.alloc, "\n");
        for (trailers) |trailer| {
            try buf.appendSlice(self.alloc, "\n");
            try buf.appendSlice(self.alloc, trailer[0]);
            try buf.appendSlice(self.alloc, ": ");
            try buf.appendSlice(self.alloc, trailer[1]);
        }

        const new_msg = try buf.toOwnedSlice(self.alloc);
        defer self.alloc.free(new_msg);

        const r = try self.runChecked(&.{ "commit", "--amend", "-m", new_msg });
        r.deinit(self.alloc);
    }

    // ── Checkout ──

    pub fn checkout(self: *const GitCli, ref: []const u8) !void {
        const r = try self.runChecked(&.{ "checkout", ref });
        r.deinit(self.alloc);
    }

    // ── Init ──

    pub fn initRepo(self: *const GitCli) !void {
        const r = try self.runChecked(&.{"init"});
        r.deinit(self.alloc);
    }

    // ── Commit ──

    pub fn commit(self: *const GitCli, message: []const u8) !void {
        const r = try self.runChecked(&.{ "commit", "-m", message, "--allow-empty" });
        r.deinit(self.alloc);
    }

    pub fn addAll(self: *const GitCli) !void {
        const r = try self.runChecked(&.{ "add", "-A" });
        r.deinit(self.alloc);
    }
};
