//! Conformance tests against the official Ethereum RLP test vectors.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const rlp = @import("rlp.zig");
const serialize = rlp.serialize;
const deserialize = rlp.deserialize;
const RawValue = rlp.RawValue;

const rlptest_json = @embedFile("rlptest.json");
const invalid_rlptest_json = @embedFile("invalidRLPTest.json");

const rlpListShortHeader = 0xc0;

/// The `in` field of a vector: a byte string, an integer, or a list of those.
const Value = union(enum) {
    bytes: []const u8,
    int: u512,
    list: []const Value,

    pub fn encodeToRLP(self: Value, allocator: Allocator, out: *ArrayList(u8)) !void {
        return switch (self) {
            .bytes => |b| serialize([]const u8, allocator, b, out),
            .int => |i| serialize(u512, allocator, i, out),
            .list => |l| serialize([]const Value, allocator, l, out),
        };
    }
};

/// Integers too large for JSON are written as `#<decimal>`. The widest vector
/// is 2^256, so u512 covers every case with room to spare.
fn parseValue(arena: Allocator, json: std.json.Value) !Value {
    return switch (json) {
        .string => |s| if (s.len > 0 and s[0] == '#')
            Value{ .int = try std.fmt.parseInt(u512, s[1..], 10) }
        else
            Value{ .bytes = s },
        .integer => |i| if (i < 0) error.NegativeVectorInteger else Value{ .int = @intCast(i) },
        .number_string => |s| Value{ .int = try std.fmt.parseInt(u512, s, 10) },
        .array => |a| blk: {
            const items = try arena.alloc(Value, a.items.len);
            for (a.items, items) |src, *dst| dst.* = try parseValue(arena, src);
            break :blk Value{ .list = items };
        },
        else => error.UnsupportedVectorInput,
    };
}

/// The `out` field is hex, `0x`-prefixed in rlptest.json but bare in most of
/// invalidRLPTest.json.
fn hexToBytes(arena: Allocator, hex_in: []const u8) ![]const u8 {
    const hex = if (std.mem.startsWith(u8, hex_in, "0x")) hex_in[2..] else hex_in;
    const buf = try arena.alloc(u8, hex.len / 2);
    return std.fmt.hexToBytes(buf, hex);
}

fn caseObject(json: std.json.Value) std.json.ObjectMap {
    return json.object;
}

test "official vectors: encoding matches" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, rlptest_json, .{});
    try testing.expectEqual(@as(usize, 28), parsed.value.object.count());

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const case = caseObject(entry.value_ptr.*);
        const input = try parseValue(arena, case.get("in").?);
        const expected = try hexToBytes(arena, case.get("out").?.string);

        var out = ArrayList(u8).init(arena);
        defer out.deinit();
        serialize(Value, arena, input, &out) catch |err| {
            std.debug.print("vector \"{s}\": encoding failed: {s}\n", .{ name, @errorName(err) });
            return err;
        };
        testing.expectEqualSlices(u8, expected, out.items) catch |err| {
            std.debug.print("vector \"{s}\": encoding mismatch\n", .{name});
            return err;
        };
    }
}

/// Decodes `encoded` and checks it against the vector's expected value.
fn expectDecodes(arena: Allocator, expected: Value, encoded: []const u8) !void {
    switch (expected) {
        .bytes => |b| {
            var out: []const u8 = undefined;
            try testing.expectEqual(encoded.len, try deserialize([]const u8, arena, encoded, &out));
            try testing.expectEqualSlices(u8, b, out);
        },
        .int => |i| {
            var out: u512 = undefined;
            try testing.expectEqual(encoded.len, try deserialize(u512, arena, encoded, &out));
            try testing.expectEqual(i, out);
        },
        .list => |l| {
            var items: []RawValue = undefined;
            try testing.expectEqual(encoded.len, try deserialize([]RawValue, arena, encoded, &items));
            try testing.expectEqual(l.len, items.len);
            for (l, items) |child, raw| try expectDecodes(arena, child, raw.value);
        },
    }
}

test "official vectors: decoding matches" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, rlptest_json, .{});

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const case = caseObject(entry.value_ptr.*);
        const input = try parseValue(arena, case.get("in").?);
        const encoded = try hexToBytes(arena, case.get("out").?.string);

        expectDecodes(arena, input, encoded) catch |err| {
            std.debug.print("vector \"{s}\": decoding failed: {s}\n", .{ name, @errorName(err) });
            return err;
        };
    }
}

/// Fully validates an RLP item: the framing must describe exactly `buf`, and
/// every element of every nested list must do the same.
fn validate(arena: Allocator, buf: []const u8) !void {
    var item: RawValue = undefined;
    const consumed = try deserialize(RawValue, arena, buf, &item);
    if (consumed != buf.len) return error.TrailingBytes;

    if (buf[0] >= rlpListShortHeader) {
        var items: []RawValue = undefined;
        _ = try deserialize([]RawValue, arena, buf, &items);
        for (items) |child| try validate(arena, child.value);
    }
}

/// Invalid vectors this decoder accepts on purpose.
const accepted_non_canonical = [_][]const u8{
    "bytesShouldBeSingleByte00",
    "bytesShouldBeSingleByte01",
    "bytesShouldBeSingleByte7F",
    "incorrectLengthInArray",
    "leadingZerosInLongLengthArray1",
    "leadingZerosInLongLengthArray2",
    "leadingZerosInLongLengthList1",
    "leadingZerosInLongLengthList2",
    "nonOptimalLongLengthArray1",
    "nonOptimalLongLengthArray2",
    "nonOptimalLongLengthList1",
    "nonOptimalLongLengthList2",
    "randomRLP",
    "wrongSizeList",
    "wrongSizeList2",
};

test "official vectors: invalid encodings are rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, invalid_rlptest_json, .{});
    try testing.expectEqual(@as(usize, 26), parsed.value.object.count());

    var failures: usize = 0;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const case = caseObject(entry.value_ptr.*);
        const encoded = try hexToBytes(arena, case.get("out").?.string);

        var non_canonical = false;
        for (accepted_non_canonical) |listed| {
            if (std.mem.eql(u8, name, listed)) non_canonical = true;
        }

        // The check runs both ways so the allow-list cannot rot: a case that
        // starts being rejected has to be removed from it.
        if (validate(arena, encoded)) |_| {
            if (!non_canonical) {
                std.debug.print("invalid vector \"{s}\" was accepted\n", .{name});
                failures += 1;
            }
        } else |err| {
            if (non_canonical) {
                std.debug.print(
                    "invalid vector \"{s}\" is listed as accepted but was rejected with {s}\n",
                    .{ name, @errorName(err) },
                );
                failures += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

/// Builds a random RLP value tree: byte strings, integers, and, above depth 0,
/// lists of those.
fn randomValue(arena: Allocator, random: std.Random, depth: usize) !Value {
    const kinds: u8 = if (depth == 0) 2 else 3;
    return switch (random.uintLessThan(u8, kinds)) {
        0 => blk: {
            // Lengths straddle the 55/56-byte short/long-form boundary.
            const payload = try arena.alloc(u8, random.uintLessThan(usize, 70));
            random.bytes(payload);
            break :blk Value{ .bytes = payload };
        },
        1 => blk: {
            var bytes: [64]u8 = undefined;
            random.bytes(&bytes);
            break :blk Value{ .int = std.mem.readInt(u512, &bytes, .big) >> random.int(u9) };
        },
        else => blk: {
            const items = try arena.alloc(Value, random.uintLessThan(usize, 5));
            for (items) |*item| item.* = try randomValue(arena, random, depth - 1);
            break :blk Value{ .list = items };
        },
    };
}

test "random value trees survive an encode/decode round-trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Fixed seed: a failure has to be reproducible.
    var prng = std.Random.DefaultPrng.init(0x5eed_1234_abcd_0003);
    const random = prng.random();

    for (0..512) |_| {
        const tree = try randomValue(arena, random, 3);

        var encoded = ArrayList(u8).init(arena);
        try serialize(Value, arena, tree, &encoded);

        // Structure and payloads must come back exactly, at every level.
        try expectDecodes(arena, tree, encoded.items);

        // The framing must also be self-consistent: nothing left over and every
        // nested item accounted for.
        try validate(arena, encoded.items);
    }
}
