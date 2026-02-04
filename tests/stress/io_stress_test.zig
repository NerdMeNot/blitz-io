//! Stress tests for blitz_io I/O utilities
//!
//! Tests buffered I/O, copy operations, and line iteration under load.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const io = blitz_io.io;
const Scope = blitz_io.Scope;

// Use smaller iteration counts in debug mode for faster test runs
const is_debug = builtin.mode == .Debug;
const LARGE_DATA_SIZE: usize = if (is_debug) 10_000 else 100_000;
const MEDIUM_ITERATIONS: usize = if (is_debug) 100 else 1000;
const SMALL_ITERATIONS: usize = if (is_debug) 1_000 else 10_000;
const LINE_COUNT: usize = if (is_debug) 100 else 1000;

// ─────────────────────────────────────────────────────────────────────────────
// Test Fixtures
// ─────────────────────────────────────────────────────────────────────────────

const TestReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn read(self: *TestReader, dest: []u8) !usize {
        if (self.pos >= self.data.len) return 0;

        const remaining = self.data[self.pos..];
        const to_copy = @min(remaining.len, dest.len);
        @memcpy(dest[0..to_copy], remaining[0..to_copy]);
        self.pos += to_copy;
        return to_copy;
    }

    pub fn reset(self: *TestReader) void {
        self.pos = 0;
    }
};

const TestWriter = struct {
    data: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TestWriter {
        return .{ .data = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *TestWriter) void {
        self.data.deinit(self.allocator);
    }

    pub fn write(self: *TestWriter, data_to_write: []const u8) !usize {
        try self.data.appendSlice(self.allocator, data_to_write);
        return data_to_write.len;
    }

    pub fn writeAll(self: *TestWriter, data_to_write: []const u8) !void {
        try self.data.appendSlice(self.allocator, data_to_write);
    }

    pub fn getWritten(self: *const TestWriter) []const u8 {
        return self.data.items;
    }

    pub fn clear(self: *TestWriter) void {
        self.data.clearRetainingCapacity();
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Copy Stress Tests
// ─────────────────────────────────────────────────────────────────────────────

test "copy stress - large data transfer" {
    const allocator = testing.allocator;

    // Create large test data (1MB in release, 64KB in debug)
    const data_size = if (is_debug) 64 * 1024 else 1024 * 1024;
    const large_data = try allocator.alloc(u8, data_size);
    defer allocator.free(large_data);

    // Fill with pattern
    for (large_data, 0..) |*b, i| {
        b.* = @truncate(i);
    }

    var reader = TestReader{ .data = large_data };
    var writer = TestWriter.init(allocator);
    defer writer.deinit();

    const copied = try io.copy(&reader, &writer);

    try testing.expectEqual(@as(u64, data_size), copied);
    try testing.expectEqualSlices(u8, large_data, writer.getWritten());
}

test "copy stress - many small copies" {
    const allocator = testing.allocator;
    const iterations = MEDIUM_ITERATIONS;

    var writer = TestWriter.init(allocator);
    defer writer.deinit();

    var total_copied: u64 = 0;

    for (0..iterations) |i| {
        // Create small data for each iteration
        var small_data: [100]u8 = undefined;
        for (&small_data, 0..) |*b, j| {
            b.* = @truncate(i + j);
        }

        var reader = TestReader{ .data = &small_data };
        total_copied += try io.copy(&reader, &writer);
    }

    try testing.expectEqual(@as(u64, iterations * 100), total_copied);
    try testing.expectEqual(@as(usize, iterations * 100), writer.getWritten().len);
}

test "copy stress - copyN boundary conditions" {
    const allocator = testing.allocator;
    const data = "0123456789";

    // Copy exact amounts at various boundaries
    const test_sizes = [_]u64{ 1, 2, 5, 9, 10 };

    for (test_sizes) |size| {
        var reader = TestReader{ .data = data };
        var writer = TestWriter.init(allocator);
        defer writer.deinit();

        const copied = try io.copyN(&reader, &writer, size);
        try testing.expectEqual(size, copied);
        try testing.expectEqual(@as(usize, @intCast(size)), writer.getWritten().len);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Buffered I/O Stress Tests
// ─────────────────────────────────────────────────────────────────────────────

test "BufReader stress - many small reads" {
    const allocator = testing.allocator;

    // Create test data
    const data_size = LARGE_DATA_SIZE;
    const test_data = try allocator.alloc(u8, data_size);
    defer allocator.free(test_data);

    for (test_data, 0..) |*b, i| {
        b.* = @truncate(i);
    }

    const reader = TestReader{ .data = test_data };
    var buf_reader = io.BufReader(TestReader).init(reader);

    // Read one byte at a time
    var received: usize = 0;
    while (true) {
        var buf: [1]u8 = undefined;
        const n = try buf_reader.read(&buf);
        if (n == 0) break;
        try testing.expectEqual(@as(u8, @truncate(received)), buf[0]);
        received += 1;
    }

    try testing.expectEqual(data_size, received);
}

test "BufReader stress - mixed read sizes" {
    const allocator = testing.allocator;

    const data_size = LARGE_DATA_SIZE / 2;
    const test_data = try allocator.alloc(u8, data_size);
    defer allocator.free(test_data);

    for (test_data, 0..) |*b, i| {
        b.* = @truncate(i);
    }

    const reader = TestReader{ .data = test_data };
    var buf_reader = io.BufReader(TestReader).init(reader);

    var received: usize = 0;
    var read_count: usize = 0;
    const read_sizes = [_]usize{ 1, 7, 13, 64, 128, 1024, 4096, 8192, 16384 };

    while (received < data_size) {
        const size = read_sizes[read_count % read_sizes.len];
        var buf: [16384]u8 = undefined;
        const n = try buf_reader.read(buf[0..size]);
        if (n == 0) break;
        received += n;
        read_count += 1;
    }

    try testing.expectEqual(data_size, received);
}

test "BufWriter stress - many small writes" {
    const allocator = testing.allocator;

    const writer = TestWriter.init(allocator);
    var buf_writer = io.BufWriter(TestWriter).init(writer);
    defer buf_writer.writer().deinit();

    // Write one byte at a time
    const iterations = SMALL_ITERATIONS;
    for (0..iterations) |i| {
        try buf_writer.writeByte(@truncate(i));
    }

    try buf_writer.flush();

    try testing.expectEqual(@as(usize, iterations), buf_writer.writer().getWritten().len);
}

test "BufWriter stress - mixed write sizes" {
    const allocator = testing.allocator;

    const writer = TestWriter.init(allocator);
    var buf_writer = io.BufWriter(TestWriter).init(writer);
    defer buf_writer.writer().deinit();

    const write_sizes = [_]usize{ 1, 5, 13, 64, 128, 512, 1024, 4096, 8192 };
    var total_written: usize = 0;

    for (0..100) |i| {
        const size = write_sizes[i % write_sizes.len];
        var data: [8192]u8 = undefined;
        @memset(data[0..size], @truncate(i));
        try buf_writer.writeAll(data[0..size]);
        total_written += size;
    }

    try buf_writer.flush();

    try testing.expectEqual(total_written, buf_writer.writer().getWritten().len);
}

// ─────────────────────────────────────────────────────────────────────────────
// Lines Iterator Stress Tests
// ─────────────────────────────────────────────────────────────────────────────

test "Lines stress - many lines" {
    const allocator = testing.allocator;

    // Generate test data with many lines
    var data_builder: std.ArrayList(u8) = .empty;
    defer data_builder.deinit(allocator);

    const line_count = LINE_COUNT;
    for (0..line_count) |i| {
        const line = try std.fmt.allocPrint(allocator, "line {d}: some test data here\n", .{i});
        defer allocator.free(line);
        try data_builder.appendSlice(allocator, line);
    }

    const reader = TestReader{ .data = data_builder.items };
    var buf_reader = io.BufReader(TestReader).init(reader);
    var buf: [1024]u8 = undefined;
    var lines_iter = io.linesWithBuffer(&buf_reader, &buf);

    var count: usize = 0;
    while (try lines_iter.next()) |_| {
        count += 1;
    }

    try testing.expectEqual(line_count, count);
}

test "Lines stress - long lines" {
    const allocator = testing.allocator;

    // Generate lines of varying lengths
    var data_builder: std.ArrayList(u8) = .empty;
    defer data_builder.deinit(allocator);

    const lengths = [_]usize{ 10, 100, 500, 1000, 2000, 4000 };
    for (lengths) |len| {
        try data_builder.appendNTimes(allocator, 'x', len);
        try data_builder.append(allocator, '\n');
    }

    const reader = TestReader{ .data = data_builder.items };
    var buf_reader = io.BufReader(TestReader).init(reader);
    var buf: [8192]u8 = undefined;
    var lines_iter = io.linesWithBuffer(&buf_reader, &buf);

    var count: usize = 0;
    for (lengths) |expected_len| {
        if (try lines_iter.next()) |line| {
            try testing.expectEqual(expected_len, line.len);
            count += 1;
        }
    }

    try testing.expectEqual(lengths.len, count);
}

// ─────────────────────────────────────────────────────────────────────────────
// Concurrent I/O Stress Tests
// ─────────────────────────────────────────────────────────────────────────────

test "FixedBufferReader/Writer stress - concurrent pattern" {
    const allocator = testing.allocator;

    var scope = Scope.init(allocator);
    defer scope.deinit();

    var results: [10]std.atomic.Value(u64) = undefined;
    for (&results) |*r| {
        r.* = std.atomic.Value(u64).init(0);
    }

    // Spawn multiple tasks that each do independent I/O operations
    for (0..10) |i| {
        try scope.spawn(independentIoTask, .{ @as(u64, @intCast(i)), &results[i] });
    }

    try scope.wait();

    // Verify each task completed successfully
    for (results) |r| {
        try testing.expect(r.load(.acquire) > 0);
    }
}

fn independentIoTask(task_id: u64, result: *std.atomic.Value(u64)) void {
    // Each task does independent reader/writer operations
    const data = "Hello from task!";
    var reader = io.FixedBufferReader.init(data);
    var r = reader.reader();

    var buf: [32]u8 = undefined;
    const n = r.read(&buf) catch 0;

    if (n == data.len) {
        result.store(task_id + 1, .release);
    }
}

test "LimitedReader stress - multiple limits" {
    const data = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

    // Test various limit sizes
    const limits = [_]usize{ 1, 5, 10, 26, 50, 62 };

    for (limits) |limit| {
        var reader = io.FixedBufferReader.init(data);
        var r = reader.reader();

        var lr = r.limitedReader(limit);
        var limited = lr.reader();

        var buf: [100]u8 = undefined;
        var total: usize = 0;
        while (true) {
            const n = try limited.read(&buf);
            if (n == 0) break;
            total += n;
        }

        try testing.expectEqual(limit, total);
    }
}

test "CountingWriter stress - accurate counting" {
    var buf: [100_000]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&buf);
    var counting = io.CountingWriter.init(writer.writer());
    var w = counting.writer();

    // Write various amounts
    var expected_total: usize = 0;
    for (0..100) |i| {
        const write_size = (i % 50) + 1;
        var data: [50]u8 = undefined;
        @memset(&data, @truncate(i));
        try w.writeAll(data[0..write_size]);
        expected_total += write_size;
    }

    try testing.expectEqual(expected_total, counting.bytes_written);
}

// ─────────────────────────────────────────────────────────────────────────────
// Edge Case Stress Tests
// ─────────────────────────────────────────────────────────────────────────────

test "FixedBufferWriter stress - exact capacity usage" {
    // Test writing exactly to capacity multiple times with reset
    var buf: [1000]u8 = undefined;
    var writer = io.FixedBufferWriter.init(&buf);

    for (0..100) |_| {
        var w = writer.writer();

        // Write exactly 1000 bytes
        var data: [100]u8 = undefined;
        @memset(&data, 'x');
        for (0..10) |_| {
            try w.writeAll(&data);
        }

        try testing.expectEqual(@as(usize, 1000), writer.getWritten().len);
        writer.reset();
        try testing.expectEqual(@as(usize, 0), writer.getWritten().len);
    }
}

test "NullWriter stress - high throughput discard" {
    var w = io.NullWriter.writer();

    // Write a lot of data that gets discarded
    var data: [8192]u8 = undefined;
    @memset(&data, 'x');

    for (0..SMALL_ITERATIONS) |_| {
        try w.writeAll(&data);
    }

    // Just verify no crash
}
