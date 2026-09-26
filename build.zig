const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tai = b.addModule("tai", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = tai });
    const test_step = b.step("test", "Run unit and mock-server tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const examples_step = b.step("examples", "Build the examples");
    inline for (.{ "triage", "dynamic", "models" }) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "tai", .module = tai }},
            }),
        });
        examples_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step("run-" ++ name, "Run the " ++ name ++ " example (needs TYPESAFE_API_KEY)").dependOn(&run.step);
    }

    const docs_step = b.step("docs", "Generate API reference into zig-out/docs/api");
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/api",
    }).step);
}
