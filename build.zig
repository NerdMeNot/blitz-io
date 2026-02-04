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

    // Backend tests
    const backend_test_mod = b.createModule(.{
        .root_source_file = b.path("src/backend.zig"),
        .target = target,
        .optimize = optimize,
    });

    const backend_tests = b.addTest(.{
        .root_module = backend_test_mod,
    });

    const run_backend_tests = b.addRunArtifact(backend_tests);
    test_step.dependOn(&run_backend_tests.step);

    // Executor stress tests (legacy, now part of test-stress)
    const executor_stress_mod = b.createModule(.{
        .root_source_file = b.path("src/executor/stress_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const executor_stress_tests = b.addTest(.{
        .root_module = executor_stress_mod,
    });

    const run_executor_stress = b.addRunArtifact(executor_stress_tests);
    test_step.dependOn(&run_executor_stress.step);

    // ========================================================================
    // Integration Tests (tests/ directory)
    // ========================================================================
    const integration_step = b.step("test-integration", "Run integration tests");

    inline for (.{
        "tests/integration/scope_test.zig",
        "tests/integration/runtime_test.zig",
        "tests/integration/tcp_integration_test.zig",
        "tests/integration/patterns_test.zig",
    }) |test_file| {
        const mod = b.createModule(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("blitz-io", blitz_io_mod);

        const t = b.addTest(.{ .root_module = mod });
        integration_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ========================================================================
    // Stress Tests
    // ========================================================================
    const stress_step = b.step("test-stress", "Run stress tests");

    inline for (.{
        "tests/stress/scope_stress_test.zig",
        "tests/stress/channel_stress_test.zig",
        "tests/stress/mutex_stress_test.zig",
    }) |test_file| {
        const mod = b.createModule(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("blitz-io", blitz_io_mod);

        const t = b.addTest(.{ .root_module = mod });
        stress_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Also include executor stress test
    stress_step.dependOn(&run_executor_stress.step);

    // ========================================================================
    // Robustness Tests
    // ========================================================================
    const robustness_step = b.step("test-robustness", "Run robustness tests");

    inline for (.{
        "tests/robustness/scope_robustness_test.zig",
        "tests/robustness/address_robustness_test.zig",
    }) |test_file| {
        const mod = b.createModule(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("blitz-io", blitz_io_mod);

        const t = b.addTest(.{ .root_module = mod });
        robustness_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ========================================================================
    // Fuzz Tests
    // ========================================================================
    const fuzz_step = b.step("test-fuzz", "Run fuzz tests");

    inline for (.{
        "tests/fuzz/address_fuzz_test.zig",
    }) |test_file| {
        const mod = b.createModule(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("blitz-io", blitz_io_mod);

        const t = b.addTest(.{ .root_module = mod });
        fuzz_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ========================================================================
    // Interop Tests
    // ========================================================================
    const interop_step = b.step("test-interop", "Run interoperability tests");

    inline for (.{
        "tests/interop/tcp_interop_test.zig",
    }) |test_file| {
        const mod = b.createModule(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("blitz-io", blitz_io_mod);

        const t = b.addTest(.{ .root_module = mod });
        interop_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ========================================================================
    // All Tests
    // ========================================================================
    const test_all_step = b.step("test-all", "Run all tests");
    test_all_step.dependOn(test_step);
    test_all_step.dependOn(integration_step);
    test_all_step.dependOn(stress_step);
    test_all_step.dependOn(robustness_step);
    test_all_step.dependOn(fuzz_step);
    test_all_step.dependOn(interop_step);

    // ========================================================================
    // Stress Test Executable (standalone runner)
    // ========================================================================
    const stress_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/executor/stress_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const stress_exe = b.addExecutable(.{
        .name = "stress-test",
        .root_module = stress_exe_mod,
    });

    b.installArtifact(stress_exe);

    const run_stress_exe = b.addRunArtifact(stress_exe);
    const stress_run_step = b.step("stress", "Run scheduler stress tests (executable)");
    stress_run_step.dependOn(&run_stress_exe.step);

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

    // ========================================================================
    // Benchmarks
    // ========================================================================
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
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
