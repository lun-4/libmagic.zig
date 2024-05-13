const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("libmagic", .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addStaticLibrary(.{
        .name = "libmagic.zig",
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = optimize,
        .target = target,
    });

    lib.linkLibrary(dep.artifact("libmagic"));

    b.installArtifact(lib);

    const test_exe = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_test = b.addRunArtifact(test_exe);
    test_exe.linkLibrary(dep.artifact("libmagic"));

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_test.step);
}
