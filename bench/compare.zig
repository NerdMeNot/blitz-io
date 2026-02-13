//! Blitz-IO vs Tokio Comparative Benchmark
//!
//! Builds and runs Blitz-IO (Zig) and Tokio (Rust) benchmarks,
//! then displays a formatted comparison table with resource usage.
//!
//! Usage: zig build compare

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
    const dim = "\x1b[2m";
    const bold = "\x1b[1m";
    const reset = "\x1b[0m";
};

// ============================================================================
// Benchmark Entry
// ============================================================================

const BenchEntry = struct {
    ns_per_op: f64 = 0,
    ops_per_sec: f64 = 0,
    bytes_per_op: f64 = 0,
    allocs_per_op: f64 = 0,
    peak_bytes: usize = 0,
};

const BenchmarkResults = struct {
    // Metadata
    benchmark_size: u64 = 0,
    channel_size: u64 = 0,
    iterations: u64 = 0,
    warmup_iterations: u64 = 0,
    num_workers: u64 = 0,

    // Benchmarks
    mutex: BenchEntry = .{},
    mutex_contended: BenchEntry = .{},
    rwlock_read: BenchEntry = .{},
    rwlock_write: BenchEntry = .{},
    rwlock_contended: BenchEntry = .{},
    semaphore: BenchEntry = .{},
    semaphore_contended: BenchEntry = .{},
    channel_send: BenchEntry = .{},
    channel_recv: BenchEntry = .{},
    channel_roundtrip: BenchEntry = .{},
    channel_mpmc: BenchEntry = .{},
    oneshot: BenchEntry = .{},
    broadcast: BenchEntry = .{},
    watch: BenchEntry = .{},
    oncecell_get: BenchEntry = .{},
    oncecell_set: BenchEntry = .{},
    barrier: BenchEntry = .{},
    notify: BenchEntry = .{},
};

// ============================================================================
// JSON Parsing
// ============================================================================

fn parseJsonResults(json_str: []const u8) BenchmarkResults {
    var results = BenchmarkResults{};
    var current_bench: ?*BenchEntry = null;

    var lines = std.mem.splitScalar(u8, json_str, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '{' or trimmed[0] == '}') continue;

        if (std.mem.indexOf(u8, trimmed, ":")) |colon_idx| {
            const key = std.mem.trim(u8, trimmed[0..colon_idx], " \t\"");
            const value_str = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t,");

            // Remove trailing brace if present
            if (std.mem.endsWith(u8, value_str, "{")) {
                // Start of a benchmark entry
                current_bench = getBenchEntry(&results, key);
                continue;
            }

            // Metadata
            if (std.mem.eql(u8, key, "benchmark_size")) {
                results.benchmark_size = std.fmt.parseInt(u64, value_str, 10) catch 0;
            } else if (std.mem.eql(u8, key, "channel_size")) {
                results.channel_size = std.fmt.parseInt(u64, value_str, 10) catch 0;
            } else if (std.mem.eql(u8, key, "iterations")) {
                results.iterations = std.fmt.parseInt(u64, value_str, 10) catch 0;
            } else if (std.mem.eql(u8, key, "warmup_iterations")) {
                results.warmup_iterations = std.fmt.parseInt(u64, value_str, 10) catch 0;
            } else if (std.mem.eql(u8, key, "num_workers")) {
                results.num_workers = std.fmt.parseInt(u64, value_str, 10) catch 0;
            }
            // Benchmark fields
            else if (current_bench) |bench| {
                if (std.mem.eql(u8, key, "ns_per_op")) {
                    bench.ns_per_op = std.fmt.parseFloat(f64, value_str) catch 0;
                } else if (std.mem.eql(u8, key, "ops_per_sec")) {
                    bench.ops_per_sec = std.fmt.parseFloat(f64, value_str) catch 0;
                } else if (std.mem.eql(u8, key, "bytes_per_op")) {
                    bench.bytes_per_op = std.fmt.parseFloat(f64, value_str) catch 0;
                } else if (std.mem.eql(u8, key, "allocs_per_op")) {
                    bench.allocs_per_op = std.fmt.parseFloat(f64, value_str) catch 0;
                } else if (std.mem.eql(u8, key, "peak_bytes")) {
                    bench.peak_bytes = std.fmt.parseInt(usize, value_str, 10) catch 0;
                }
            }
        }
    }

    return results;
}

fn getBenchEntry(results: *BenchmarkResults, name: []const u8) ?*BenchEntry {
    if (std.mem.eql(u8, name, "mutex")) return &results.mutex;
    if (std.mem.eql(u8, name, "mutex_contended")) return &results.mutex_contended;
    if (std.mem.eql(u8, name, "rwlock_read")) return &results.rwlock_read;
    if (std.mem.eql(u8, name, "rwlock_write")) return &results.rwlock_write;
    if (std.mem.eql(u8, name, "rwlock_contended")) return &results.rwlock_contended;
    if (std.mem.eql(u8, name, "semaphore")) return &results.semaphore;
    if (std.mem.eql(u8, name, "semaphore_contended")) return &results.semaphore_contended;
    if (std.mem.eql(u8, name, "channel_send")) return &results.channel_send;
    if (std.mem.eql(u8, name, "channel_recv")) return &results.channel_recv;
    if (std.mem.eql(u8, name, "channel_roundtrip")) return &results.channel_roundtrip;
    if (std.mem.eql(u8, name, "channel_mpmc")) return &results.channel_mpmc;
    if (std.mem.eql(u8, name, "oneshot")) return &results.oneshot;
    if (std.mem.eql(u8, name, "broadcast")) return &results.broadcast;
    if (std.mem.eql(u8, name, "watch")) return &results.watch;
    if (std.mem.eql(u8, name, "oncecell_get")) return &results.oncecell_get;
    if (std.mem.eql(u8, name, "oncecell_set")) return &results.oncecell_set;
    if (std.mem.eql(u8, name, "barrier")) return &results.barrier;
    if (std.mem.eql(u8, name, "notify")) return &results.notify;
    return null;
}

// ============================================================================
// Table Drawing
// ============================================================================

const TableWriter = struct {
    const w1 = 22; // Benchmark name
    const w2 = 10; // Blitz ns
    const w3 = 10; // Tokio ns
    const w4 = 10; // Blitz B/op
    const w5 = 10; // Tokio B/op
    const w6 = 14; // Winner

    fn printHeader(title: []const u8) void {
        std.debug.print("\n{s}{s}{s}\n", .{ Color.bold, title, Color.reset });
    }

    fn printTopBorder() void {
        std.debug.print("{s}", .{"\u{250C}"});
        printDash(w1 + 2);
        std.debug.print("{s}", .{"\u{252C}"});
        printDash(w2 + 2);
        std.debug.print("{s}", .{"\u{252C}"});
        printDash(w3 + 2);
        std.debug.print("{s}", .{"\u{252C}"});
        printDash(w4 + 2);
        std.debug.print("{s}", .{"\u{252C}"});
        printDash(w5 + 2);
        std.debug.print("{s}", .{"\u{252C}"});
        printDash(w6 + 2);
        std.debug.print("{s}\n", .{"\u{2510}"});
    }

    fn printMidBorder() void {
        std.debug.print("{s}", .{"\u{251C}"});
        printDash(w1 + 2);
        std.debug.print("{s}", .{"\u{253C}"});
        printDash(w2 + 2);
        std.debug.print("{s}", .{"\u{253C}"});
        printDash(w3 + 2);
        std.debug.print("{s}", .{"\u{253C}"});
        printDash(w4 + 2);
        std.debug.print("{s}", .{"\u{253C}"});
        printDash(w5 + 2);
        std.debug.print("{s}", .{"\u{253C}"});
        printDash(w6 + 2);
        std.debug.print("{s}\n", .{"\u{2524}"});
    }

    fn printBottomBorder() void {
        std.debug.print("{s}", .{"\u{2514}"});
        printDash(w1 + 2);
        std.debug.print("{s}", .{"\u{2534}"});
        printDash(w2 + 2);
        std.debug.print("{s}", .{"\u{2534}"});
        printDash(w3 + 2);
        std.debug.print("{s}", .{"\u{2534}"});
        printDash(w4 + 2);
        std.debug.print("{s}", .{"\u{2534}"});
        printDash(w5 + 2);
        std.debug.print("{s}", .{"\u{2534}"});
        printDash(w6 + 2);
        std.debug.print("{s}\n", .{"\u{2518}"});
    }

    fn printDash(count: usize) void {
        for (0..count) |_| {
            std.debug.print("{s}", .{"\u{2500}"});
        }
    }

    fn printTableHeader() void {
        std.debug.print("\u{2502} {s:<" ++ std.fmt.comptimePrint("{d}", .{w1}) ++
            "} \u{2502} {s:>" ++ std.fmt.comptimePrint("{d}", .{w2}) ++
            "} \u{2502} {s:>" ++ std.fmt.comptimePrint("{d}", .{w3}) ++
            "} \u{2502} {s:>" ++ std.fmt.comptimePrint("{d}", .{w4}) ++
            "} \u{2502} {s:>" ++ std.fmt.comptimePrint("{d}", .{w5}) ++
            "} \u{2502} {s:<" ++ std.fmt.comptimePrint("{d}", .{w6}) ++ "} \u{2502}\n", .{
            "Benchmark", "Blitz ns", "Tokio ns", "Blitz B/op", "Tokio B/op", "Winner",
        });
    }

    fn printRow(name: []const u8, blitz: BenchEntry, tokio: BenchEntry, bufs: *Bufs) void {
        const blitz_ns = std.fmt.bufPrint(&bufs.b1, "{d:.1}", .{blitz.ns_per_op}) catch "N/A";
        const tokio_ns = std.fmt.bufPrint(&bufs.b2, "{d:.1}", .{tokio.ns_per_op}) catch "N/A";
        const blitz_bytes = std.fmt.bufPrint(&bufs.b3, "{d:.1}", .{blitz.bytes_per_op}) catch "N/A";
        const tokio_bytes = std.fmt.bufPrint(&bufs.b4, "{d:.1}", .{tokio.bytes_per_op}) catch "N/A";
        const winner = findWinner(blitz.ns_per_op, tokio.ns_per_op, &bufs.b5);

        std.debug.print("\u{2502} {s:<" ++ std.fmt.comptimePrint("{d}", .{w1}) ++
            "} \u{2502} {s:>" ++ std.fmt.comptimePrint("{d}", .{w2}) ++
            "} \u{2502} {s:>" ++ std.fmt.comptimePrint("{d}", .{w3}) ++
            "} \u{2502} {s:>" ++ std.fmt.comptimePrint("{d}", .{w4}) ++
            "} \u{2502} {s:>" ++ std.fmt.comptimePrint("{d}", .{w5}) ++
            "} \u{2502} {s:<" ++ std.fmt.comptimePrint("{d}", .{w6}) ++ "} \u{2502}\n", .{
            name, blitz_ns, tokio_ns, blitz_bytes, tokio_bytes, winner,
        });
    }

    fn findWinner(blitz_ns: f64, tokio_ns: f64, buf: *[48]u8) []const u8 {
        if (blitz_ns == 0 and tokio_ns == 0) return "N/A";
        if (blitz_ns == 0) return std.fmt.bufPrint(buf, "{s}Tokio{s}", .{ Color.yellow, Color.reset }) catch "Tokio";
        if (tokio_ns == 0) return std.fmt.bufPrint(buf, "{s}Blitz{s}", .{ Color.green, Color.reset }) catch "Blitz";

        const ratio = tokio_ns / blitz_ns;

        if (@abs(ratio - 1.0) < 0.05) {
            return "Tie";
        }

        if (blitz_ns < tokio_ns) {
            return std.fmt.bufPrint(buf, "{s}Blitz +{d:.1}x{s}", .{ Color.green, ratio, Color.reset }) catch "Blitz";
        } else {
            const inv_ratio = blitz_ns / tokio_ns;
            return std.fmt.bufPrint(buf, "{s}Tokio +{d:.1}x{s}", .{ Color.yellow, inv_ratio, Color.reset }) catch "Tokio";
        }
    }

    const Bufs = struct {
        b1: [32]u8 = undefined,
        b2: [32]u8 = undefined,
        b3: [32]u8 = undefined,
        b4: [32]u8 = undefined,
        b5: [48]u8 = undefined,
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

    var stdout_buf: [4 * 1024 * 1024]u8 = undefined;
    var stderr_buf: [4 * 1024 * 1024]u8 = undefined;

    const stdout_len = child.stdout.?.readAll(&stdout_buf) catch 0;
    const stderr_len = child.stderr.?.readAll(&stderr_buf) catch 0;

    const term = try child.wait();
    const success = term.Exited == 0;

    const stdout = try allocator.dupe(u8, stdout_buf[0..stdout_len]);
    const stderr = try allocator.dupe(u8, stderr_buf[0..stderr_len]);

    return .{ .stdout = stdout, .stderr = stderr, .success = success };
}

fn getProjectDir(allocator: std.mem.Allocator) ![]const u8 {
    const exe_path = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(exe_path);

    if (std.mem.indexOf(u8, exe_path, ".zig-cache")) |_| {
        const project_dir = try std.fs.path.resolve(allocator, &.{ exe_path, "..", "..", ".." });
        return project_dir;
    } else {
        const project_dir = try std.fs.path.resolve(allocator, &.{ exe_path, "..", ".." });
        return project_dir;
    }
}

// ============================================================================
// Summary Stats
// ============================================================================

const CompareResult = struct {
    blitz_wins: u32 = 0,
    tokio_wins: u32 = 0,
    ties: u32 = 0,
    blitz_total_bytes: f64 = 0,
    tokio_total_bytes: f64 = 0,
    blitz_total_allocs: f64 = 0,
    tokio_total_allocs: f64 = 0,

    fn compare(self: *CompareResult, blitz: BenchEntry, tokio: BenchEntry) void {
        if (blitz.ns_per_op > 0 and tokio.ns_per_op > 0) {
            const ratio = tokio.ns_per_op / blitz.ns_per_op;
            if (@abs(ratio - 1.0) < 0.05) {
                self.ties += 1;
            } else if (blitz.ns_per_op < tokio.ns_per_op) {
                self.blitz_wins += 1;
            } else {
                self.tokio_wins += 1;
            }
        }

        self.blitz_total_bytes += blitz.bytes_per_op;
        self.tokio_total_bytes += tokio.bytes_per_op;
        self.blitz_total_allocs += blitz.allocs_per_op;
        self.tokio_total_allocs += tokio.allocs_per_op;
    }
};

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
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════════════{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}                    BLITZ-IO vs TOKIO COMPARATIVE BENCHMARK{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════════════{s}\n\n", .{ Color.bold, Color.reset });

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

    const tokio_result = try runCommand(allocator, &.{ tokio_bench_path, "--json" }, rust_dir);
    defer allocator.free(tokio_result.stdout);
    defer allocator.free(tokio_result.stderr);

    if (!tokio_result.success) {
        std.debug.print("{s}Failed to run Tokio benchmark{s}\n", .{ Color.red, Color.reset });
        std.debug.print("{s}\n", .{tokio_result.stderr});
        return;
    }
    std.debug.print("{s}✓ Tokio benchmark complete{s}\n\n", .{ Color.green, Color.reset });

    // Parse results
    const blitz = parseJsonResults(blitz_result.stderr);
    const tokio = parseJsonResults(tokio_result.stdout);

    var bufs = TableWriter.Bufs{};
    var compare = CompareResult{};

    // Display comparison
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════════════{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}                         BLITZ-IO vs TOKIO COMPARISON{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════════════{s}\n", .{ Color.bold, Color.reset });

    // 1. Synchronization (uncontended)
    TableWriter.printHeader("1. SYNCHRONIZATION - Uncontended (lower is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader();
    TableWriter.printMidBorder();
    TableWriter.printRow("Mutex", blitz.mutex, tokio.mutex, &bufs);
    compare.compare(blitz.mutex, tokio.mutex);
    TableWriter.printRow("RwLock (read)", blitz.rwlock_read, tokio.rwlock_read, &bufs);
    compare.compare(blitz.rwlock_read, tokio.rwlock_read);
    TableWriter.printRow("RwLock (write)", blitz.rwlock_write, tokio.rwlock_write, &bufs);
    compare.compare(blitz.rwlock_write, tokio.rwlock_write);
    TableWriter.printRow("Semaphore", blitz.semaphore, tokio.semaphore, &bufs);
    compare.compare(blitz.semaphore, tokio.semaphore);
    TableWriter.printBottomBorder();

    // 2. Synchronization (contended - spin-wait)
    TableWriter.printHeader("2. SYNCHRONIZATION - Contended/Spin-wait (lower is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader();
    TableWriter.printMidBorder();
    TableWriter.printRow("Mutex (4 threads)", blitz.mutex_contended, tokio.mutex_contended, &bufs);
    compare.compare(blitz.mutex_contended, tokio.mutex_contended);
    TableWriter.printRow("RwLock (4R + 2W)", blitz.rwlock_contended, tokio.rwlock_contended, &bufs);
    compare.compare(blitz.rwlock_contended, tokio.rwlock_contended);
    TableWriter.printRow("Semaphore (8T, 2 perm)", blitz.semaphore_contended, tokio.semaphore_contended, &bufs);
    compare.compare(blitz.semaphore_contended, tokio.semaphore_contended);
    TableWriter.printBottomBorder();

    // 3. Channels
    TableWriter.printHeader("3. CHANNELS (lower is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader();
    TableWriter.printMidBorder();
    TableWriter.printRow("Channel send", blitz.channel_send, tokio.channel_send, &bufs);
    compare.compare(blitz.channel_send, tokio.channel_send);
    TableWriter.printRow("Channel recv", blitz.channel_recv, tokio.channel_recv, &bufs);
    compare.compare(blitz.channel_recv, tokio.channel_recv);
    TableWriter.printRow("Channel roundtrip", blitz.channel_roundtrip, tokio.channel_roundtrip, &bufs);
    compare.compare(blitz.channel_roundtrip, tokio.channel_roundtrip);
    TableWriter.printRow("Channel MPMC (4P + 4C)", blitz.channel_mpmc, tokio.channel_mpmc, &bufs);
    compare.compare(blitz.channel_mpmc, tokio.channel_mpmc);
    TableWriter.printRow("Oneshot", blitz.oneshot, tokio.oneshot, &bufs);
    compare.compare(blitz.oneshot, tokio.oneshot);
    TableWriter.printRow("Broadcast (4 recv)", blitz.broadcast, tokio.broadcast, &bufs);
    compare.compare(blitz.broadcast, tokio.broadcast);
    TableWriter.printRow("Watch", blitz.watch, tokio.watch, &bufs);
    compare.compare(blitz.watch, tokio.watch);
    TableWriter.printBottomBorder();

    // 4. Once Cell
    TableWriter.printHeader("4. ONCE CELL (lower is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader();
    TableWriter.printMidBorder();
    TableWriter.printRow("OnceCell get (hot)", blitz.oncecell_get, tokio.oncecell_get, &bufs);
    compare.compare(blitz.oncecell_get, tokio.oncecell_get);
    TableWriter.printRow("OnceCell set", blitz.oncecell_set, tokio.oncecell_set, &bufs);
    compare.compare(blitz.oncecell_set, tokio.oncecell_set);
    TableWriter.printBottomBorder();

    // 5. Coordination
    TableWriter.printHeader("5. COORDINATION (lower is better)");
    TableWriter.printTopBorder();
    TableWriter.printTableHeader();
    TableWriter.printMidBorder();
    TableWriter.printRow("Barrier", blitz.barrier, tokio.barrier, &bufs);
    compare.compare(blitz.barrier, tokio.barrier);
    TableWriter.printRow("Notify", blitz.notify, tokio.notify, &bufs);
    compare.compare(blitz.notify, tokio.notify);
    TableWriter.printBottomBorder();

    // Legend
    std.debug.print("\n{s}══════════════════════════════════════════════════════════════════════════════════════{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}                                     LEGEND{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════════════{s}\n\n", .{ Color.bold, Color.reset });
    std.debug.print("  {s}Blitz-IO{s}   = Blitz-IO sync primitives (Zig)\n", .{ Color.green, Color.reset });
    std.debug.print("  {s}Tokio{s}      = Tokio sync primitives (Rust)\n\n", .{ Color.yellow, Color.reset });
    std.debug.print("  Benchmark size: {d} operations\n", .{blitz.benchmark_size});
    std.debug.print("  Channel size: {d}\n", .{blitz.channel_size});
    std.debug.print("  Iterations: {d} (after {d} warmup)\n", .{ blitz.iterations, blitz.warmup_iterations });
    std.debug.print("  Workers: {d}\n", .{blitz.num_workers});

    // Summary
    std.debug.print("\n{s}══════════════════════════════════════════════════════════════════════════════════════{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}                                    SUMMARY{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("{s}══════════════════════════════════════════════════════════════════════════════════════{s}\n\n", .{ Color.bold, Color.reset });

    const total = compare.blitz_wins + compare.tokio_wins + compare.ties;
    std.debug.print("  {s}Performance:{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("    Benchmarks compared:   {d}\n", .{total});
    std.debug.print("    {s}Blitz-IO wins:{s}         {d}\n", .{ Color.green, Color.reset, compare.blitz_wins });
    std.debug.print("    {s}Tokio wins:{s}            {d}\n", .{ Color.yellow, Color.reset, compare.tokio_wins });
    std.debug.print("    Ties:                  {d}\n\n", .{compare.ties});

    std.debug.print("  {s}Resource Usage (total B/op across all benchmarks):{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("    {s}Blitz-IO:{s}              {d:.1} bytes/op\n", .{ Color.green, Color.reset, compare.blitz_total_bytes });
    std.debug.print("    {s}Tokio:{s}                 {d:.1} bytes/op\n\n", .{ Color.yellow, Color.reset, compare.tokio_total_bytes });

    std.debug.print("  {s}Allocations (total allocs/op across all benchmarks):{s}\n", .{ Color.bold, Color.reset });
    std.debug.print("    {s}Blitz-IO:{s}              {d:.4} allocs/op\n", .{ Color.green, Color.reset, compare.blitz_total_allocs });
    std.debug.print("    {s}Tokio:{s}                 {d:.4} allocs/op\n\n", .{ Color.yellow, Color.reset, compare.tokio_total_allocs });

    if (compare.blitz_wins > compare.tokio_wins) {
        std.debug.print("  {s}{s}Blitz-IO leads overall!{s}\n\n", .{ Color.green, Color.bold, Color.reset });
    } else if (compare.tokio_wins > compare.blitz_wins) {
        std.debug.print("  {s}{s}Tokio leads overall{s}\n\n", .{ Color.yellow, Color.bold, Color.reset });
    } else {
        std.debug.print("  {s}{s}It's a tie!{s}\n\n", .{ Color.cyan, Color.bold, Color.reset });
    }

    std.debug.print("  {s}Note:{s} Blitz-IO is inspired by Tokio's design. Thanks to the\n", .{ Color.bold, Color.reset });
    std.debug.print("  Tokio team for their excellent work and documentation!\n\n", .{});
}
