//! Blitz-IO vs Tokio Comparative Benchmark
//!
//! Builds and runs Blitz-IO (Zig) and Tokio (Rust) benchmarks,
//! then displays a formatted comparison table.
//!
//! Usage: zig build compare
//!
//! Blitz-IO aims to bring Tokio-level async I/O performance to Zig.

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// ANSI Colors
// ============================================================================

const Color = struct {
    const red = "\x1b[0;31m";
    const green = "\x1b[0;32m";
    const yellow = "\x1b[1;33m";
    const blue = "\x1b[0;34m";
    const cyan = "\x1b[0;36m";
    const bold = "\x1b[1m";
    const reset = "\x1b[0m";
};

// ============================================================================
// JSON Parsing
// ============================================================================

const BenchmarkResults = struct {
    // Mutex
    mutex_ns: f64 = 0,
    mutex_ops_per_sec: f64 = 0,

    // RwLock
    rwlock_read_ns: f64 = 0,
    rwlock_write_ns: f64 = 0,

    // Semaphore
    semaphore_ns: f64 = 0,

    // Channel
    channel_send_ns: f64 = 0,
    channel_recv_ns: f64 = 0,
    channel_roundtrip_ns: f64 = 0,

    // Oneshot
    oneshot_ns: f64 = 0,

    // WaitGroup
    waitgroup_ns: f64 = 0,

    // Event
    event_ns: f64 = 0,

    // Throughput
    message_throughput: f64 = 0,

    // Metadata
    benchmark_size: u64 = 0,
    iterations: u64 = 0,
    warmup_iterations: u64 = 0,
    num_workers: u64 = 0,
};

fn parseJsonResults(json_str: []const u8) BenchmarkResults {
    var results = BenchmarkResults{};

    // Simple line-by-line JSON parsing
    var lines = std.mem.splitScalar(u8, json_str, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '{' or trimmed[0] == '}') continue;

        // Find key and value
        if (std.mem.indexOf(u8, trimmed, ":")) |colon_idx| {
            const key = std.mem.trim(u8, trimmed[0..colon_idx], " \t\"");
            const value_str = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t,");

            // Parse based on key
            if (std.mem.eql(u8, key, "mutex_ns")) {
                results.mutex_ns = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "mutex_ops_per_sec")) {
                results.mutex_ops_per_sec = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "rwlock_read_ns")) {
                results.rwlock_read_ns = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "rwlock_write_ns")) {
                results.rwlock_write_ns = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "semaphore_ns")) {
                results.semaphore_ns = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "channel_send_ns")) {
                results.channel_send_ns = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "channel_recv_ns")) {
                results.channel_recv_ns = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "channel_roundtrip_ns")) {
                results.channel_roundtrip_ns = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "oneshot_ns")) {
                results.oneshot_ns = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "waitgroup_ns")) {
                results.waitgroup_ns = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "event_ns")) {
                results.event_ns = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "message_throughput")) {
                results.message_throughput = std.fmt.parseFloat(f64, value_str) catch 0;
            } else if (std.mem.eql(u8, key, "benchmark_size")) {
                results.benchmark_size = std.fmt.parseInt(u64, value_str, 10) catch 0;
            } else if (std.mem.eql(u8, key, "iterations")) {
                results.iterations = std.fmt.parseInt(u64, value_str, 10) catch 0;
            } else if (std.mem.eql(u8, key, "warmup_iterations")) {
                results.warmup_iterations = std.fmt.parseInt(u64, value_str, 10) catch 0;
            } else if (std.mem.eql(u8, key, "num_workers")) {
                results.num_workers = std.fmt.parseInt(u64, value_str, 10) catch 0;
            }
        }
    }

    return results;
}

// ============================================================================
// Table Drawing
// ============================================================================

const TableWriter = struct {
    const w1 = 20; // Benchmark name
    const w2 = 14; // Blitz-IO
    const w3 = 14; // Tokio
    const w4 = 14; // Winner

    fn printHeader(title: []const u8) void {
        std.debug.print("\n{s}{s}{s}\n", .{ Color.bold, title, Color.reset });
    }

    fn printTopBorder() void {
        std.debug.print("{s}", .{"\u{250C}"}); // ┌
        printDash(w1 + 2);
        std.debug.print("{s}", .{"\u{252C}"}); // ┬
        printDash(w2 + 2);
        std.debug.print("{s}", .{"\u{252C}"}); // ┬
        printDash(w3 + 2);
        std.debug.print("{s}", .{"\u{252C}"}); // ┬
        printDash(w4 + 2);
        std.debug.print("{s}\n", .{"\u{2510}"}); // ┐
    }

    fn printMidBorder() void {
        std.debug.print("{s}", .{"\u{251C}"}); // ├
        printDash(w1 + 2);
        std.debug.print("{s}", .{"\u{253C}"}); // ┼
        printDash(w2 + 2);
        std.debug.print("{s}", .{"\u{253C}"}); // ┼
        printDash(w3 + 2);
        std.debug.print("{s}", .{"\u{253C}"}); // ┼
        printDash(w4 + 2);
        std.debug.print("{s}\n", .{"\u{2524}"}); // ┤
    }

    fn printBottomBorder() void {
        std.debug.print("{s}", .{"\u{2514}"}); // └
        printDash(w1 + 2);
        std.debug.print("{s}", .{"\u{2534}"}); // ┴
        printDash(w2 + 2);
        std.debug.print("{s}", .{"\u{2534}"}); // ┴
        printDash(w3 + 2);
        std.debug.print("{s}", .{"\u{2534}"}); // ┴
        printDash(w4 + 2);
        std.debug.print("{s}\n", .{"\u{2518}"}); // ┘
    }

    fn printDash(count: usize) void {
        for (0..count) |_| {
            std.debug.print("{s}", .{"\u{2500}"}); // ─
        }
    }

    fn printTableHeader() void {
        printRow4("Benchmark", "Blitz-IO", "Tokio", "Winner");
    }

    fn printRow4(name: []const u8, c1: []const u8, c2: []const u8, c3: []const u8) void {
        std.debug.print("\u{2502} {s:<" ++ std.fmt.comptimePrint("{d}", .{w1}) ++
            "} \u{2502} {s:>" ++ std.fmt.comptimePrint("{d}", .{w2}) ++
            "} \u{2502} {s:>" ++ std.fmt.comptimePrint("{d}", .{w3}) ++
            "} \u{2502} {s:<" ++ std.fmt.comptimePrint("{d}", .{w4}) ++ "} \u{2502}\n", .{ name, c1, c2, c3 });
    }

    fn printNsRow(name: []const u8, blitz_ns: f64, tokio_ns: f64, bufs: *Bufs) void {
        const blitz_str = std.fmt.bufPrint(&bufs.b1, "{d:.1}ns", .{blitz_ns}) catch "N/A";
        const tokio_str = std.fmt.bufPrint(&bufs.b2, "{d:.1}ns", .{tokio_ns}) catch "N/A";
        const winner = findWinner(blitz_ns, tokio_ns, &bufs.b3, true);
        printRow4(name, blitz_str, tokio_str, winner);
    }

    fn printThroughputRow(name: []const u8, blitz_ops: f64, tokio_ops: f64, bufs: *Bufs) void {
        const blitz_str = formatThroughput(blitz_ops, &bufs.b1);
        const tokio_str = formatThroughput(tokio_ops, &bufs.b2);
        const winner = findWinner(blitz_ops, tokio_ops, &bufs.b3, false); // higher is better
        printRow4(name, blitz_str, tokio_str, winner);
    }

    fn formatThroughput(ops: f64, buf: *[32]u8) []const u8 {
        if (ops >= 1_000_000) {
            return std.fmt.bufPrint(buf, "{d:.2}M/s", .{ops / 1_000_000.0}) catch "N/A";
        } else if (ops >= 1_000) {
            return std.fmt.bufPrint(buf, "{d:.2}K/s", .{ops / 1_000.0}) catch "N/A";
        } else {
            return std.fmt.bufPrint(buf, "{d:.0}/s", .{ops}) catch "N/A";
        }
    }

    fn findWinner(blitz_val: f64, tokio_val: f64, buf: *[48]u8, lower_is_better: bool) []const u8 {
        if (blitz_val == 0 and tokio_val == 0) return "N/A";
        if (blitz_val == 0) return std.fmt.bufPrint(buf, "{s}Tokio{s}", .{ Color.yellow, Color.reset }) catch "Tokio";
        if (tokio_val == 0) return std.fmt.bufPrint(buf, "{s}Blitz-IO{s}", .{ Color.green, Color.reset }) catch "Blitz-IO";

        const blitz_better = if (lower_is_better) blitz_val < tokio_val else blitz_val > tokio_val;
        const ratio = if (lower_is_better) tokio_val / blitz_val else blitz_val / tokio_val;

        if (@abs(ratio - 1.0) < 0.05) {
            return "Tie";
        }

        if (blitz_better) {
            return std.fmt.bufPrint(buf, "{s}Blitz +{d:.1}x{s}", .{ Color.green, ratio, Color.reset }) catch "Blitz-IO";
        } else {
            const inv_ratio = 1.0 / ratio;
            return std.fmt.bufPrint(buf, "{s}Tokio +{d:.1}x{s}", .{ Color.yellow, 1.0 / inv_ratio, Color.reset }) catch "Tokio";
        }
    }

    const Bufs = struct {
        b1: [32]u8 = undefined,
        b2: [32]u8 = undefined,
        b3: [48]u8 = undefined,
    };
};

// ============================================================================
// Subprocess Execution
// ============================================================================

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !struct { stdout: []u8, stderr: []u8, success: bool } {
    var child = std.process.Child.init(argv, allocator);
    if (cwd) |dir| {
        child.cwd = dir;
    }
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Read stdout and stderr
    var stdout_buf: [1024 * 1024]u8 = undefined;
    var stderr_buf: [1024 * 1024]u8 = undefined;

    const stdout_len = child.stdout.?.readAll(&stdout_buf) catch 0;
    const stderr_len = child.stderr.?.readAll(&stderr_buf) catch 0;

    const term = try child.wait();
    const success = term.Exited == 0;

    // Copy to owned slices
    const stdout = try allocator.dupe(u8, stdout_buf[0..stdout_len]);
    const stderr = try allocator.dupe(u8, stderr_buf[0..stderr_len]);

    return .{ .stdout = stdout, .stderr = stderr, .success = success };
}

fn getProjectDir(allocator: std.mem.Allocator) ![]const u8 {
    // Get the directory containing the executable
    const exe_path = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(exe_path);

    // Check if we're in .zig-cache or zig-out/bin
    if (std.mem.indexOf(u8, exe_path, ".zig-cache")) |_| {
        const project_dir = try std.fs.path.resolve(allocator, &.{ exe_path, "..", "..", ".." });
        return project_dir;
    } else {
        const project_dir = try std.fs.path.resolve(allocator, &.{ exe_path, "..", ".." });
        return project_dir;
    }
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const project_dir = try getProjectDir(allocator);
    defer allocator.free(project_dir);

    const bench_dir = try std.fs.path.join(allocator, &.{ project_dir, "bench" });
    defer allocator.free(bench_dir);

    const rust_dir = try std.fs.path.join(allocator, &.{ bench_dir, "rust_bench" });
    defer allocator.free(rust_dir);

    // Print header
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}                  BLITZ-IO vs TOKIO COMPARATIVE BENCHMARK{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════{s}\n\n", .{ Color.bold, Color.reset });

    // Build Rust/Tokio benchmark
    std.debug.print("{s}Building Tokio benchmark...{s}\n", .{ Color.blue, Color.reset });
    const cargo_result = try runCommand(allocator, &.{ "cargo", "build", "--release" }, rust_dir);
    defer allocator.free(cargo_result.stdout);
    defer allocator.free(cargo_result.stderr);

    if (!cargo_result.success) {
        std.debug.print("{s}Failed to build Tokio benchmark{s}\n", .{ Color.red, Color.reset });
        std.debug.print("{s}\n", .{cargo_result.stderr});
        return;
    }
    std.debug.print("{s}✓ Tokio build complete{s}\n", .{ Color.green, Color.reset });

    // Run Blitz-IO benchmark
    std.debug.print("{s}Running Blitz-IO benchmark...{s}\n", .{ Color.blue, Color.reset });

    // The blitz_bench is installed to zig-out/bench/blitz_bench
    const zig_out_bench = try std.fs.path.join(allocator, &.{ project_dir, "zig-out", "bench" });
    defer allocator.free(zig_out_bench);
    const blitz_bench_path = try std.fs.path.join(allocator, &.{ zig_out_bench, "blitz_bench" });
    defer allocator.free(blitz_bench_path);

    const blitz_result = try runCommand(allocator, &.{ blitz_bench_path, "--json" }, bench_dir);
    defer allocator.free(blitz_result.stdout);
    defer allocator.free(blitz_result.stderr);

    if (!blitz_result.success) {
        std.debug.print("{s}Failed to run Blitz-IO benchmark{s}\n", .{ Color.red, Color.reset });
        std.debug.print("stdout: {s}\n", .{blitz_result.stdout});
        std.debug.print("stderr: {s}\n", .{blitz_result.stderr});
        return;
    }
    std.debug.print("{s}✓ Blitz-IO benchmark complete{s}\n", .{ Color.green, Color.reset });

    // Run Tokio benchmark
    std.debug.print("{s}Running Tokio benchmark...{s}\n", .{ Color.blue, Color.reset });

    const tokio_bench_path = try std.fs.path.join(allocator, &.{ rust_dir, "target", "release", "blitz_rust_bench" });
    defer allocator.free(tokio_bench_path);

    const tokio_result = try runCommand(allocator, &.{tokio_bench_path}, rust_dir);
    defer allocator.free(tokio_result.stdout);
    defer allocator.free(tokio_result.stderr);

    if (!tokio_result.success) {
        std.debug.print("{s}Failed to run Tokio benchmark{s}\n", .{ Color.red, Color.reset });
        std.debug.print("{s}\n", .{tokio_result.stderr});
        return;
    }
    std.debug.print("{s}✓ Tokio benchmark complete{s}\n\n", .{ Color.green, Color.reset });

    // Parse results (blitz outputs JSON to stderr, tokio to stdout)
    const blitz_results = parseJsonResults(blitz_result.stderr);
    const tokio_results = parseJsonResults(tokio_result.stdout);

    // Display comparison
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}                       BLITZ-IO vs TOKIO COMPARISON{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════{s}\n", .{ Color.bold, Color.reset });

    var bufs = TableWriter.Bufs{};

    // 1. Synchronization Primitives
    TableWriter.printHeader("1. SYNCHRONIZATION (lower is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader();
    TableWriter.printMidBorder();
    TableWriter.printNsRow("Mutex", blitz_results.mutex_ns, tokio_results.mutex_ns, &bufs);
    TableWriter.printNsRow("RwLock (read)", blitz_results.rwlock_read_ns, tokio_results.rwlock_read_ns, &bufs);
    TableWriter.printNsRow("RwLock (write)", blitz_results.rwlock_write_ns, tokio_results.rwlock_write_ns, &bufs);
    TableWriter.printNsRow("Semaphore", blitz_results.semaphore_ns, tokio_results.semaphore_ns, &bufs);
    TableWriter.printBottomBorder();

    // 2. Channel Operations
    TableWriter.printHeader("2. CHANNELS (lower is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader();
    TableWriter.printMidBorder();
    TableWriter.printNsRow("Send", blitz_results.channel_send_ns, tokio_results.channel_send_ns, &bufs);
    TableWriter.printNsRow("Recv", blitz_results.channel_recv_ns, tokio_results.channel_recv_ns, &bufs);
    TableWriter.printNsRow("Roundtrip", blitz_results.channel_roundtrip_ns, tokio_results.channel_roundtrip_ns, &bufs);
    TableWriter.printNsRow("Oneshot", blitz_results.oneshot_ns, tokio_results.oneshot_ns, &bufs);
    TableWriter.printBottomBorder();

    // 3. Coordination Primitives
    TableWriter.printHeader("3. COORDINATION (lower is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader();
    TableWriter.printMidBorder();
    TableWriter.printNsRow("WaitGroup", blitz_results.waitgroup_ns, tokio_results.waitgroup_ns, &bufs);
    TableWriter.printNsRow("Event", blitz_results.event_ns, tokio_results.event_ns, &bufs);
    TableWriter.printBottomBorder();

    // 4. Throughput
    TableWriter.printHeader("4. THROUGHPUT (higher is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader();
    TableWriter.printMidBorder();
    TableWriter.printThroughputRow("Mutex ops", blitz_results.mutex_ops_per_sec, tokio_results.mutex_ops_per_sec, &bufs);
    TableWriter.printThroughputRow("Messages", blitz_results.message_throughput, tokio_results.message_throughput, &bufs);
    TableWriter.printBottomBorder();

    // Legend
    std.debug.print("\n{s}══════════════════════════════════════════════════════════════════════════════{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}                                   LEGEND{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════{s}\n\n", .{ Color.bold, Color.reset });
    std.debug.print("  {s}Blitz-IO{s}   = Blitz-IO async runtime (Zig)\n", .{ Color.green, Color.reset });
    std.debug.print("  {s}Tokio{s}      = Tokio async runtime (Rust)\n\n", .{ Color.yellow, Color.reset });
    std.debug.print("  Benchmark size: {d} operations\n", .{blitz_results.benchmark_size});
    std.debug.print("  Iterations: {d} (after {d} warmup)\n", .{ blitz_results.iterations, blitz_results.warmup_iterations });
    std.debug.print("  Workers: {d}\n", .{blitz_results.num_workers});

    // Summary
    std.debug.print("\n{s}══════════════════════════════════════════════════════════════════════════════{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}                                  SUMMARY{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════{s}\n\n", .{ Color.bold, Color.reset });

    // Count wins
    var blitz_wins: u32 = 0;
    var tokio_wins: u32 = 0;
    var ties: u32 = 0;

    // Compare all metrics (lower is better for ns metrics)
    const ns_comparisons = [_]struct { b: f64, t: f64 }{
        .{ .b = blitz_results.mutex_ns, .t = tokio_results.mutex_ns },
        .{ .b = blitz_results.rwlock_read_ns, .t = tokio_results.rwlock_read_ns },
        .{ .b = blitz_results.rwlock_write_ns, .t = tokio_results.rwlock_write_ns },
        .{ .b = blitz_results.semaphore_ns, .t = tokio_results.semaphore_ns },
        .{ .b = blitz_results.channel_send_ns, .t = tokio_results.channel_send_ns },
        .{ .b = blitz_results.channel_recv_ns, .t = tokio_results.channel_recv_ns },
        .{ .b = blitz_results.channel_roundtrip_ns, .t = tokio_results.channel_roundtrip_ns },
        .{ .b = blitz_results.oneshot_ns, .t = tokio_results.oneshot_ns },
        .{ .b = blitz_results.waitgroup_ns, .t = tokio_results.waitgroup_ns },
        .{ .b = blitz_results.event_ns, .t = tokio_results.event_ns },
    };

    for (ns_comparisons) |cmp| {
        if (cmp.b > 0 and cmp.t > 0) {
            const ratio = cmp.t / cmp.b;
            if (@abs(ratio - 1.0) < 0.05) {
                ties += 1;
            } else if (cmp.b < cmp.t) {
                blitz_wins += 1;
            } else {
                tokio_wins += 1;
            }
        }
    }

    // Throughput comparisons (higher is better)
    const throughput_comparisons = [_]struct { b: f64, t: f64 }{
        .{ .b = blitz_results.mutex_ops_per_sec, .t = tokio_results.mutex_ops_per_sec },
        .{ .b = blitz_results.message_throughput, .t = tokio_results.message_throughput },
    };

    for (throughput_comparisons) |cmp| {
        if (cmp.b > 0 and cmp.t > 0) {
            const ratio = cmp.b / cmp.t;
            if (@abs(ratio - 1.0) < 0.05) {
                ties += 1;
            } else if (cmp.b > cmp.t) {
                blitz_wins += 1;
            } else {
                tokio_wins += 1;
            }
        }
    }

    const total = blitz_wins + tokio_wins + ties;
    std.debug.print("  Benchmarks compared: {d}\n", .{total});
    std.debug.print("  {s}Blitz-IO wins:{s}     {d}\n", .{ Color.green, Color.reset, blitz_wins });
    std.debug.print("  {s}Tokio wins:{s}        {d}\n", .{ Color.yellow, Color.reset, tokio_wins });
    std.debug.print("  Ties:             {d}\n\n", .{ties});

    if (blitz_wins > tokio_wins) {
        std.debug.print("  {s}{s}Blitz-IO leads overall!{s}\n\n", .{ Color.green, Color.bold, Color.reset });
    } else if (tokio_wins > blitz_wins) {
        std.debug.print("  {s}{s}Tokio leads overall{s}\n\n", .{ Color.yellow, Color.bold, Color.reset });
    } else {
        std.debug.print("  {s}{s}It's a tie!{s}\n\n", .{ Color.cyan, Color.bold, Color.reset });
    }

    std.debug.print("  {s}Note:{s} Blitz-IO is inspired by Tokio's design. Thanks to the\n", .{ Color.bold, Color.reset });
    std.debug.print("  Tokio team for their excellent work and documentation!\n\n", .{});
}
