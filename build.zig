const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Vendored SQLite as a static library ---
    const sqlite_lib = b.addLibrary(.{
        .name = "sqlite3",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    sqlite_lib.addCSourceFile(.{
        .file = b.path("deps/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_DQS=0",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_DEFAULT_JOURNAL_MODE_WAL=1",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_JSON1",
        },
    });
    sqlite_lib.addIncludePath(b.path("deps/sqlite"));

    // --- SQLite Zig module ---
    const sqlite_mod = b.addModule("sqlite", .{
        .root_source_file = b.path("src/sqlite.zig"),
        .target = target,
        .optimize = optimize,
    });
    sqlite_mod.addIncludePath(b.path("deps/sqlite"));
    sqlite_mod.linkLibrary(sqlite_lib);

    // --- Main executable ---
    const exe = b.addExecutable(.{
        .name = "agx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sqlite", .module = sqlite_mod },
            },
        }),
    });

    b.installArtifact(exe);

    // --- Run step ---
    const run_step = b.step("run", "Run agx");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // --- Tests ---
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/sqlite.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addIncludePath(b.path("deps/sqlite"));
    test_mod.linkLibrary(sqlite_lib);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
