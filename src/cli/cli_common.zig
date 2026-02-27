const std = @import("std");
const Allocator = std.mem.Allocator;
const agx = @import("agx");

/// Bundles the common resources needed by most CLI commands:
/// git handle, git dir path, db path, and an open store.
pub const CliContext = struct {
    git: agx.GitCli,
    git_dir: []u8,
    db_path: [:0]u8,
    store: agx.Store,
    alloc: Allocator,

    /// Open the agx store for the current git repo.
    /// Prints diagnostics to stderr and calls process.exit(1) on failure.
    pub fn open(alloc: Allocator, stderr: *std.Io.Writer) CliContext {
        const git = agx.GitCli.init(alloc, null);

        const git_dir = git.gitDir() catch {
            stderr.print("error: not a git repository\n", .{}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };

        const db_path = std.fmt.allocPrintSentinel(alloc, "{s}/agx/db.sqlite3", .{git_dir}, 0) catch {
            alloc.free(git_dir);
            stderr.print("error: out of memory\n", .{}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };

        std.fs.cwd().access(db_path[0..db_path.len :0], .{}) catch {
            alloc.free(db_path);
            alloc.free(git_dir);
            stderr.print("error: agx not initialized. Run 'agx init' first.\n", .{}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };

        const store = agx.Store.init(alloc, db_path) catch {
            alloc.free(db_path);
            alloc.free(git_dir);
            stderr.print("error: could not open database\n", .{}) catch {};
            stderr.flush() catch {};
            std.process.exit(1);
        };

        return .{
            .git = git,
            .git_dir = git_dir,
            .db_path = db_path,
            .store = store,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *CliContext) void {
        self.store.deinit();
        self.alloc.free(self.db_path);
        self.alloc.free(self.git_dir);
    }
};
