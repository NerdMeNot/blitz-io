//! Fuzz tests for Address parsing
//!
//! Randomized input to find crashes and unexpected behavior.

const std = @import("std");
const testing = std.testing;
const blitz_io = @import("blitz-io");
const Address = blitz_io.Address;

test "Address fuzz - random strings should not crash" {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    var buf: [256]u8 = undefined;

    for (0..1000) |_| {
        const len = random.intRangeAtMost(usize, 0, buf.len - 1);
        random.bytes(buf[0..len]);

        // Should not crash, may return error
        _ = Address.parse(buf[0..len]) catch continue;
    }
}

test "Address fuzz - variations on valid pattern" {
    var prng = std.Random.DefaultPrng.init(54321);
    const random = prng.random();

    const base = "127.0.0.1:8080";
    var buf: [32]u8 = undefined;

    for (0..1000) |_| {
        // Copy base
        @memcpy(buf[0..base.len], base);
        const len = base.len;

        // Randomly mutate a character
        const pos = random.intRangeLessThan(usize, 0, len);
        buf[pos] = random.int(u8);

        // Should not crash
        _ = Address.parse(buf[0..len]) catch continue;
    }
}

test "Address fuzz - varying lengths with valid chars" {
    var prng = std.Random.DefaultPrng.init(98765);
    const random = prng.random();

    const chars = "0123456789.:[]";

    var buf: [64]u8 = undefined;

    for (0..1000) |_| {
        const len = random.intRangeAtMost(usize, 1, 32);

        for (buf[0..len]) |*c| {
            const idx = random.intRangeLessThan(usize, 0, chars.len);
            c.* = chars[idx];
        }

        // Should not crash
        _ = Address.parse(buf[0..len]) catch continue;
    }
}

test "Address fuzz - port number edge cases" {
    var prng = std.Random.DefaultPrng.init(11111);
    const random = prng.random();

    for (0..1000) |_| {
        // Generate random port number string
        const port = random.int(u32);
        var port_buf: [16]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch continue;

        // Build address string
        var addr_buf: [32]u8 = undefined;
        const addr_str = std.fmt.bufPrint(&addr_buf, "127.0.0.1:{s}", .{port_str}) catch continue;

        // Parse - should not crash
        _ = Address.parse(addr_str) catch continue;
    }
}

test "Address fuzz - IPv6 variations" {
    var prng = std.Random.DefaultPrng.init(22222);
    const random = prng.random();

    const hex_chars = "0123456789abcdef";

    var buf: [64]u8 = undefined;

    for (0..500) |_| {
        // Build random IPv6-like string: [xxxx:xxxx:...]:port
        var pos: usize = 0;
        buf[pos] = '[';
        pos += 1;

        // Add some hex groups
        const num_groups = random.intRangeAtMost(usize, 1, 8);
        for (0..num_groups) |g| {
            if (g > 0) {
                buf[pos] = ':';
                pos += 1;
            }
            const group_len = random.intRangeAtMost(usize, 0, 4);
            for (0..group_len) |_| {
                buf[pos] = hex_chars[random.intRangeLessThan(usize, 0, hex_chars.len)];
                pos += 1;
            }
        }

        buf[pos] = ']';
        pos += 1;
        buf[pos] = ':';
        pos += 1;

        // Add port
        const port = random.intRangeAtMost(u16, 0, 65535);
        const port_slice = std.fmt.bufPrint(buf[pos..], "{d}", .{port}) catch continue;
        pos += port_slice.len;

        // Parse - should not crash
        _ = Address.parse(buf[0..pos]) catch continue;
    }
}
