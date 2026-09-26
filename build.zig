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
    const test_step = b.step("test", "Run offline tests, compile e2e tests, and check doc snippets");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // End-to-end tests against the live API. Every Zig example in the docs is
    // quoted from these, so `zig build test` compiles them and the consumer
    // project, and `zig build e2e` runs them.
    const e2e_tests = b.addTest(.{
        .name = "e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "tai", .module = tai }},
        }),
    });
    test_step.dependOn(&e2e_tests.step);

    const consumer_build = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    consumer_build.setCwd(b.path("tests/consumer"));
    consumer_build.has_side_effects = true;
    test_step.dependOn(&consumer_build.step);

    const e2e_step = b.step("e2e", "Run end-to-end tests and the quick start against the live API (needs TYPESAFE_API_KEY)");
    const run_e2e = b.addRunArtifact(e2e_tests);
    run_e2e.has_side_effects = true;
    e2e_step.dependOn(&run_e2e.step);
    const consumer_run = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "run" });
    consumer_run.setCwd(b.path("tests/consumer"));
    consumer_run.has_side_effects = true;
    e2e_step.dependOn(&consumer_run.step);

    const snippets_tool = b.addExecutable(.{
        .name = "snippets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/snippets.zig"),
            .target = b.graph.host,
        }),
    });
    const snippets_step = b.step("snippets", "Extract doc snippets from the tests and update the docs");
    const snippets_write = b.addRunArtifact(snippets_tool);
    snippets_write.addArg("write");
    snippets_write.setCwd(b.path("."));
    snippets_write.has_side_effects = true;
    snippets_step.dependOn(&snippets_write.step);
    const snippets_check = b.addRunArtifact(snippets_tool);
    snippets_check.addArg("check");
    snippets_check.setCwd(b.path("."));
    snippets_check.has_side_effects = true;
    test_step.dependOn(&snippets_check.step);

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
