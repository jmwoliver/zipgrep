const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "zrep",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zrep");
    run_step.dependOn(&run_cmd.step);

    // Unit tests for main module
    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Deque tests (includes multi-threaded stress tests)
    const deque_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/deque.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_deque_tests = b.addRunArtifact(deque_tests);
    const deque_test_step = b.step("test-deque", "Run deque unit and stress tests");
    deque_test_step.dependOn(&run_deque_tests.step);

    // Add deque tests to main test step as well
    test_step.dependOn(&run_deque_tests.step);

    // Gitignore tests (includes GitignoreState tests)
    const gitignore_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gitignore.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_gitignore_tests = b.addRunArtifact(gitignore_tests);
    test_step.dependOn(&run_gitignore_tests.step);

    // Parallel walker tests
    const parallel_walker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parallel_walker.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_parallel_walker_tests = b.addRunArtifact(parallel_walker_tests);
    test_step.dependOn(&run_parallel_walker_tests.step);

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    // Integration tests depend on the main executable being built
    run_integration_tests.step.dependOn(b.getInstallStep());

    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);
}
