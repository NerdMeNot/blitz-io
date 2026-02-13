const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // blitz-io Module (for downstream users)
    // ========================================================================
    const blitz_io_mod = b.addModule("blitz-io", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // Unit Tests (inline tests in source files)
    // ========================================================================
    const unit_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = unit_test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ========================================================================
    // Test Configuration (shared between test suites)
    // ========================================================================
    const test_config_mod = b.addModule("test_config", .{
        .root_source_file = b.path("tests/test_config.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Common test utilities module
    const common_mod = b.addModule("common", .{
        .root_source_file = b.path("tests/common.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ========================================================================
    // Stress Tests
    // ========================================================================
    const stress_step = b.step("test-stress", "Run stress tests");

    const stress_mod = b.createModule(.{
        .root_source_file = b.path("tests/stress/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    stress_mod.addImport("blitz-io", blitz_io_mod);
    stress_mod.addImport("test_config", test_config_mod);
    stress_mod.addImport("common", common_mod);

    const stress_tests = b.addTest(.{ .root_module = stress_mod });
    stress_step.dependOn(&b.addRunArtifact(stress_tests).step);

    // ========================================================================
    // Robustness Tests
    // ========================================================================
    const robustness_step = b.step("test-robustness", "Run robustness tests");

    const robustness_mod = b.createModule(.{
        .root_source_file = b.path("tests/robustness/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    robustness_mod.addImport("blitz-io", blitz_io_mod);
    robustness_mod.addImport("test_config", test_config_mod);
    robustness_mod.addImport("common", common_mod);

    const robustness_tests = b.addTest(.{ .root_module = robustness_mod });
    robustness_step.dependOn(&b.addRunArtifact(robustness_tests).step);

    // ========================================================================
    // Concurrency Tests (Loom-style)
    // ========================================================================
    const concurrency_step = b.step("test-concurrency", "Run concurrency tests");

    const concurrency_mod = b.createModule(.{
        .root_source_file = b.path("tests/concurrency/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    concurrency_mod.addImport("blitz-io", blitz_io_mod);
    concurrency_mod.addImport("test_config", test_config_mod);
    concurrency_mod.addImport("common", common_mod);

    const concurrency_tests = b.addTest(.{ .root_module = concurrency_mod });
    concurrency_step.dependOn(&b.addRunArtifact(concurrency_tests).step);

    // ========================================================================
    // All Tests
    // ========================================================================
    const test_all_step = b.step("test-all", "Run all tests");
    test_all_step.dependOn(test_step);
    test_all_step.dependOn(stress_step);
    test_all_step.dependOn(robustness_step);
    test_all_step.dependOn(concurrency_step);

    // ========================================================================
    // ========================================================================
    // Examples
    // ========================================================================
    const echo_server_mod = b.createModule(.{
        .root_source_file = b.path("examples/echo_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    echo_server_mod.addImport("blitz-io", blitz_io_mod);

    const echo_server_exe = b.addExecutable(.{
        .name = "echo-server",
        .root_module = echo_server_mod,
    });

    b.installArtifact(echo_server_exe);

    const run_echo_server = b.addRunArtifact(echo_server_exe);
    const echo_step = b.step("example-echo", "Run TCP echo server example");
    echo_step.dependOn(&run_echo_server.step);

    // UDP Echo Example
    const udp_echo_mod = b.createModule(.{
        .root_source_file = b.path("examples/udp_echo.zig"),
        .target = target,
        .optimize = optimize,
    });
    udp_echo_mod.addImport("blitz-io", blitz_io_mod);

    const udp_echo_exe = b.addExecutable(.{
        .name = "udp-echo",
        .root_module = udp_echo_mod,
    });

    b.installArtifact(udp_echo_exe);

    const run_udp_echo = b.addRunArtifact(udp_echo_exe);
    const udp_echo_step = b.step("example-udp-echo", "Run UDP echo server example");
    udp_echo_step.dependOn(&run_udp_echo.step);

    // Graceful Shutdown Example
    const shutdown_mod = b.createModule(.{
        .root_source_file = b.path("examples/graceful_shutdown.zig"),
        .target = target,
        .optimize = optimize,
    });
    shutdown_mod.addImport("blitz-io", blitz_io_mod);

    const shutdown_exe = b.addExecutable(.{
        .name = "graceful-shutdown",
        .root_module = shutdown_mod,
    });

    b.installArtifact(shutdown_exe);

    const run_shutdown = b.addRunArtifact(shutdown_exe);
    const shutdown_step = b.step("example-shutdown", "Run graceful shutdown example");
    shutdown_step.dependOn(&run_shutdown.step);

    // Timeout Demo Example
    const timeout_mod = b.createModule(.{
        .root_source_file = b.path("examples/timeout_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    timeout_mod.addImport("blitz-io", blitz_io_mod);

    const timeout_exe = b.addExecutable(.{
        .name = "timeout-demo",
        .root_module = timeout_mod,
    });

    b.installArtifact(timeout_exe);

    const run_timeout = b.addRunArtifact(timeout_exe);
    const timeout_step = b.step("example-timeout", "Run timeout demo example");
    timeout_step.dependOn(&run_timeout.step);

    // Combinators Demo Example
    const combinators_mod = b.createModule(.{
        .root_source_file = b.path("examples/combinators_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    combinators_mod.addImport("blitz-io", blitz_io_mod);

    const combinators_exe = b.addExecutable(.{
        .name = "combinators-demo",
        .root_module = combinators_mod,
    });

    b.installArtifact(combinators_exe);

    const run_combinators = b.addRunArtifact(combinators_exe);
    const combinators_step = b.step("example-combinators", "Run async combinators demo");
    combinators_step.dependOn(&run_combinators.step);

    // Scope Demo Example
    const scope_demo_mod = b.createModule(.{
        .root_source_file = b.path("examples/scope_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    scope_demo_mod.addImport("blitz-io", blitz_io_mod);

    const scope_demo_exe = b.addExecutable(.{
        .name = "scope-demo",
        .root_module = scope_demo_mod,
    });

    b.installArtifact(scope_demo_exe);

    const run_scope_demo = b.addRunArtifact(scope_demo_exe);
    const scope_demo_step = b.step("example-scope", "Run scope API demo");
    scope_demo_step.dependOn(&run_scope_demo.step);

    // ========================================================================
    // Benchmarks
    // ========================================================================
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/blitz_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("blitz-io", blitz_io_mod);

    const bench_exe = b.addExecutable(.{
        .name = "blitz_bench",
        .root_module = bench_mod,
    });

    const install_bench = b.addInstallArtifact(bench_exe, .{
        .dest_dir = .{ .override = .{ .custom = "bench" } },
    });

    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| {
        run_bench.addArgs(args);
    }
    run_bench.step.dependOn(&install_bench.step);

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // MPMC test (temporary - for debugging scheduler wakeup bug)
    const mpmc_mod = b.createModule(.{
        .root_source_file = b.path("bench/mpmc_test.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    mpmc_mod.addImport("blitz-io", blitz_io_mod);
    const mpmc_exe = b.addExecutable(.{
        .name = "mpmc_test",
        .root_module = mpmc_mod,
    });
    const run_mpmc = b.addRunArtifact(mpmc_exe);
    const mpmc_step = b.step("mpmc-test", "Run MPMC wakeup test");
    mpmc_step.dependOn(&run_mpmc.step);

    // Comparison benchmark (Blitz-IO vs Tokio)
    const compare_mod = b.createModule(.{
        .root_source_file = b.path("bench/compare.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const compare_exe = b.addExecutable(.{
        .name = "compare",
        .root_module = compare_mod,
    });

    const install_compare = b.addInstallArtifact(compare_exe, .{
        .dest_dir = .{ .override = .{ .custom = "bench" } },
    });

    const run_compare = b.addRunArtifact(compare_exe);
    run_compare.step.dependOn(&install_compare.step);
    run_compare.step.dependOn(&install_bench.step); // Ensure blitz_bench is built first

    const compare_step = b.step("compare", "Run Blitz-IO vs Tokio comparison benchmark");
    compare_step.dependOn(&run_compare.step);

    // ========================================================================
    // Documentation
    // ========================================================================
    const docs_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const docs_obj = b.addObject(.{
        .name = "blitz-io-docs",
        .root_module = docs_mod,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
}
