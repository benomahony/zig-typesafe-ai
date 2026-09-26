//! A downstream project that depends on tai by path. `zig build e2e` builds
//! and runs it against the live API, so the install instructions and the
//! quick start in the docs are tested exactly as written.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "quickstart",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // docs:start install-build
    const tai = b.dependency("tai", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("tai", tai.module("tai"));
    // docs:end install-build

    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run the quick start").dependOn(&run.step);
}
