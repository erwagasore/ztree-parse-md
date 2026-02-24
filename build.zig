const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ztree_dep = b.dependency("ztree", .{
        .target = target,
        .optimize = optimize,
    });

    const bun_md_dep = b.dependency("bun_md", .{});

    // Shim: provides the "bun" module that bun-md's source expects
    const bun_shim = b.createModule(.{
        .root_source_file = b.path("src/shim/bun.zig"),
    });

    // bun-md parser module with shim injected
    const md_mod = b.createModule(.{
        .root_source_file = bun_md_dep.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bun", .module = bun_shim },
        },
    });

    // Library module
    const lib_mod = b.addModule("ztree-parse-md", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztree", .module = ztree_dep.module("ztree") },
            .{ .name = "bun-md", .module = md_mod },
        },
    });

    // Library artifact (for linking)
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "ztree-parse-md",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // Tests
    const test_step = b.step("test", "Run unit tests");

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztree", .module = ztree_dep.module("ztree") },
            .{ .name = "bun-md", .module = md_mod },
        },
    });

    const t = b.addTest(.{
        .root_module = test_mod,
    });
    const run_t = b.addRunArtifact(t);
    test_step.dependOn(&run_t.step);
}
