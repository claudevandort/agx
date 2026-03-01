// Root module for agx — re-exports all submodules.

pub const ulid = @import("core/ulid.zig");
pub const goal = @import("core/goal.zig");
pub const task = @import("core/task.zig");
pub const session = @import("core/session.zig");
pub const event = @import("core/event.zig");
pub const evidence = @import("core/evidence.zig");
pub const snapshot = @import("core/snapshot.zig");
pub const dispatch = @import("core/dispatch.zig");
pub const dispatch_overlap = @import("dispatch/overlap.zig");
pub const migrations = @import("storage/migrations.zig");
pub const store = @import("storage/store.zig");
pub const git = @import("git/cli.zig");
pub const compare_metrics = @import("compare/metrics.zig");
pub const compare_renderer = @import("compare/renderer.zig");
pub const context_export = @import("storage/export.zig");
pub const ingest = @import("daemon/ingest.zig");
pub const file_watcher = @import("daemon/file_watcher.zig");
pub const json_writer = @import("util/json_writer.zig");
pub const frontmatter = @import("util/frontmatter.zig");

// Re-export key types for convenience
pub const Ulid = ulid.Ulid;
pub const Goal = goal.Goal;
pub const Task = task.Task;
pub const Session = session.Session;
pub const Event = event.Event;
pub const Evidence = evidence.Evidence;
pub const Snapshot = snapshot.Snapshot;
pub const Dispatch = dispatch.Dispatch;
pub const Store = store.Store;
pub const GitCli = git.GitCli;

test {
    // Pull in all tests from submodules
    @import("std").testing.refAllDecls(@This());
}
