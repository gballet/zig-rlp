const std = @import("std");
const serialize = @import("serialize.zig").serialize;
const common = @import("common.zig");
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const eql = std.mem.eql;
const ArrayList = std.array_list.Managed;
const hasFn = std.meta.hasFn;
const Allocator = std.mem.Allocator;

const rlpByteListShortHeader = common.rlpByteListShortHeader;
const rlpByteListLongHeader = common.rlpByteListLongHeader;
const rlpListShortHeader = common.rlpListShortHeader;
const rlpListLongHeader = common.rlpListLongHeader;

const safeReadSliceIntBig = common.safeReadSliceIntBig;
const sizeAndDataOffset = common.sizeAndDataOffset;

// Count the number of elements in a list
fn countRlpListItems(serialized: []const u8) !usize {
    var offset: usize = 0;
    var list_size: usize = 0;
    while (offset < serialized.len) : (list_size += 1) {
        const temp = try sizeAndDataOffset(serialized[offset..]);
        if (temp.size > serialized.len - offset - temp.offset) return error.RlpPayloadTooShort;
        offset += temp.offset + temp.size;
    }
    return list_size;
}

// Returns the amount of data consumed from `serialized`.
pub fn deserialize(comptime T: type, allocator: Allocator, serialized: []const u8, out: *T) !usize {
    if (comptime hasFn(T, "decodeFromRLP")) {
        return out.decodeFromRLP(allocator, serialized);
    }

    const info = @typeInfo(T);
    return switch (info) {
        .int => {
            comptime {
                // @sizeOf rounds odd-width integers up to the next power of
                // two (u24 -> 4 bytes), which desynchronizes the payload size
                // guard from readVarInt's bit-width precondition. Only accept
                // widths where @sizeOf(T) * 8 == @bitSizeOf(T).
                const bits = @typeInfo(T).int.bits;
                if (bits < 8 or !std.math.isPowerOfTwo(bits)) {
                    @compileError("RLP integers must have a power-of-two bit width of at least 8; got " ++ @typeName(T));
                }
            }
            const r = try sizeAndDataOffset(serialized);
            if (r.size > serialized.len - r.offset) return error.RlpPayloadTooShort;
            try safeReadSliceIntBig(T, serialized[r.offset .. r.offset + r.size], out);
            return r.offset + r.size;
        },
        .@"struct" => |struc| {
            if (serialized.len == 0) {
                return error.EOF;
            }
            // A structure is encoded as a list, not
            // a bitstring.
            if (serialized[0] < rlpListShortHeader) {
                return error.NotAnRLPList;
            }

            const r = try sizeAndDataOffset(serialized);
            if (r.size > serialized.len - r.offset) {
                return error.InvalidSerializedLength;
            }
            // limit of the struct's rlp encoding inside the larger buffer
            const limit = r.offset + r.size;

            var offset = r.offset;
            inline for (struc.fields) |field| {
                if (offset > limit) {
                    return error.OffsetOverflow;
                }
                offset += try deserialize(field.type, allocator, serialized[offset..limit], &@field(out.*, field.name));
            }

            return limit;
        },
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8) {
                const r = try sizeAndDataOffset(serialized);
                if (r.size > serialized.len - r.offset) return error.RlpPayloadTooShort;
                if (ptr.is_const) {
                    out.* = serialized[r.offset .. r.offset + r.size];
                } else {
                    out.* = try allocator.alloc(ptr.child, r.size);
                    std.mem.copyForwards(ptr.child, out.*, serialized[r.offset .. r.offset + r.size]);
                }
                return r.offset + r.size;
            } else {
                if (serialized[0] < rlpListShortHeader) {
                    return error.NotAnRLPList;
                }

                const r = try sizeAndDataOffset(serialized);
                if (r.size > serialized.len - r.offset) return error.RlpPayloadTooShort;
                const end = r.offset + r.size;

                const list_size = try countRlpListItems(serialized[r.offset..end]);

                // since it's not possible to say if the slice is "undefined", it has
                // to be allocated regardless.
                out.* = try allocator.alloc(ptr.child, list_size);

                var offset = r.offset;
                var i: usize = 0;
                while (offset < end) : (i += 1) {
                    offset += try deserialize(ptr.child, allocator, serialized[offset..], &out.*[i]);
                }

                return end;
            },
            .one => {
                out.* = try allocator.create(ptr.child);
                errdefer allocator.destroy(out.*);
                return deserialize(ptr.child, allocator, serialized, out.*);
            },
            // TODO missing: Many, C
            else => return error.UnsupportedType,
        },
        .array => |ary| if (@sizeOf(ary.child) == 1) {
            const r = try sizeAndDataOffset(serialized);
            if (r.size > serialized.len - r.offset) return error.RlpPayloadTooShort;
            if (r.size != ary.len) return error.RlpInvalidLength;
            // this is a fixed-size array, so the destination has already been allocated.
            std.mem.copyForwards(u8, out.*[0..], serialized[r.offset .. r.offset + r.size]);
            return r.offset + r.size;
        } else return error.UnsupportedType,
        .optional => |opt| {
            // There are two types of optional: those in the
            // middle of a structure, that MUST be represented
            // by an empty field (0x80) and those who are at
            // the end of a structure and are missing entirely
            // (typical case: block structures being extended
            // fork after fork). In this latter case, the size
            // of the payload will be shorter than the number
            // of fields, but returning an offset step of 0
            // will cause the container deserialization to
            // keep trying with the same offset, and that will
            // mark all optional values as empty.
            if (serialized.len == 0 or serialized[0] == rlpByteListShortHeader or serialized[0] == rlpListShortHeader) {
                out.* = null;
                // 0 if serialized was empty, one in the case of an empty list
                if (serialized.len == 0)
                    return 0;
                return 1;
            } else {
                var t: opt.child = undefined;
                const offset = try deserialize(opt.child, allocator, serialized[0..], &t);
                out.* = t;
                return offset;
            }
        },
        .bool => {
            const r = try sizeAndDataOffset(serialized);
            if (r.size > serialized.len - r.offset) return error.RlpPayloadTooShort;
            const payload = serialized[r.offset .. r.offset + r.size];
            out.* = switch (payload.len) {
                0 => false,
                1 => switch (payload[0]) {
                    0 => false,
                    1 => true,
                    else => return error.RlpInvalidBoolean,
                },
                else => return error.RlpInvalidBoolean,
            };
            return r.offset + r.size;
        },
        else => return error.UnsupportedType,
    };
}

test "deserialize an integer" {
    var consumed: usize = 0;

    const su8lo = [_]u8{42};
    var u8lo: u8 = undefined;
    consumed = try deserialize(u8, std.testing.allocator, su8lo[0..], &u8lo);
    try expect(u8lo == 42);
    try expect(consumed == 1);

    const su8hi = [_]u8{ 129, 192 };
    var u8hi: u8 = undefined;
    consumed = try deserialize(u8, std.testing.allocator, su8hi[0..], &u8hi);
    try expect(u8hi == 192);
    try expect(consumed == su8hi.len);

    const su16small = [_]u8{ 129, 192 };
    var u16small: u16 = undefined;
    consumed = try deserialize(u16, std.testing.allocator, su16small[0..], &u16small);
    try expect(u16small == 192);
    try expect(consumed == su16small.len);

    const su16long = [_]u8{ 130, 192, 192 };
    var u16long: u16 = undefined;
    consumed = try deserialize(u16, std.testing.allocator, su16long[0..], &u16long);
    try expect(u16long == 0xc0c0);
    try expect(consumed == su16long.len);
}

test "deserialize an integer rejects oversized payload" {
    // 0x83 = 0x80 + 3: a 3-byte byte-string payload, which is too large to
    // fit into a u16 (2 bytes). The decoder must reject this rather than
    // silently truncating the payload.
    const rlp = [_]u8{ 0x83, 0x01, 0x02, 0x03 };
    var out: u16 = undefined;
    try expectError(error.RlpIntPayloadTooLong, deserialize(u16, std.testing.allocator, rlp[0..], &out));
}

test "deserialize a structure" {
    const Person = struct {
        age: u8,
        name: []const u8,
    };
    const jc = Person{ .age = 123, .name = "Jeanne Calment" };
    var list = ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try serialize(Person, std.testing.allocator, jc, &list);
    var p: Person = undefined;
    const consumed = try deserialize(Person, std.testing.allocator, list.items[0..], &p);
    try expect(consumed == list.items.len);
    try expect(p.age == jc.age);
    try expect(eql(u8, p.name, jc.name));
}
test "deserialize a string" {
    const str = "abc";
    var list = ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try serialize([]const u8, std.testing.allocator, str, &list);
    var s: []const u8 = undefined;
    const consumed = try deserialize([]const u8, std.testing.allocator, list.items[0..], &s);
    try expect(eql(u8, str, s));
    try expect(consumed == list.items.len);
}

test "deserialize a byte array" {
    const expected = [_]u8{ 1, 2, 3 };
    var list = ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try serialize(@TypeOf(expected), std.testing.allocator, expected, &list);
    var out: [3]u8 = undefined;
    const consumed = try deserialize([3]u8, std.testing.allocator, list.items[0..], &out);
    try expect(eql(u8, expected[0..], out[0..]));
    try expect(consumed == list.items.len);
}

test "deserialize a byte arrayi with a single byte" {
    const expected = [_]u8{3};
    var list = ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try serialize(@TypeOf(expected), std.testing.allocator, expected, &list);
    var out: [1]u8 = undefined;
    const consumed = try deserialize([1]u8, std.testing.allocator, list.items[0..], &out);
    try std.testing.expectEqual(expected, out);
    try expect(consumed == list.items.len);
}

const RLPDecodablePerson = struct {
    name: []const u8,
    age: u8,

    pub fn decodeFromRLP(self: *RLPDecodablePerson, allocator: Allocator, serialized: []const u8) !usize {
        _ = allocator;
        if (serialized.len == 0) {
            return error.EOF;
        }

        self.age = serialized[0];
        self.name = "freshly deserialized person";
        return 1;
    }
};

test "deserialize with custom serializer" {
    var person: RLPDecodablePerson = undefined;
    const serialized = [_]u8{42};
    const consumed = try deserialize(RLPDecodablePerson, std.testing.allocator, serialized[0..], &person);
    try expect(person.age == serialized[0]);
    try expect(consumed == 1);
}

test "deserialize an optional" {
    var list = ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    var x: ?u32 = null;

    try serialize(?u32, std.testing.allocator, x, &list);
    var y: ?u32 = undefined;
    _ = try deserialize(?u32, std.testing.allocator, list.items, &y);
    try expect(y == null);

    list.clearAndFree();
    x = 32;
    var z: ?u32 = undefined;
    try serialize(?u32, std.testing.allocator, x, &list);
    _ = try deserialize(?u32, std.testing.allocator, list.items, &z);
    try expect(z.? == x.?);
}

test "deserialize a structure with missing optional fields at the end" {
    const structWithTrailingOptionalFields = struct {
        x: u64,
        y: ?u64,
        z: ?u64,
        alpha: ?[]const u8,
    };
    const serialized = [_]u8{ 0xc6, 0x84, 0xde, 0xad, 0xbe, 0xef, 5 };

    var mystruct: structWithTrailingOptionalFields = undefined;
    _ = try deserialize(structWithTrailingOptionalFields, std.testing.allocator, serialized[0..], &mystruct);
    try expect(mystruct.x == 0xdeadbeef);
    try expect(mystruct.y != null and mystruct.y.? == 5);
    try expect(mystruct.z == null);
    try expect(mystruct.alpha == null);
}

const Header = struct {
    parent_hash: [32]u8,
    uncle_hash: [32]u8,
    fee_recipient: [20]u8,
    state_root: [32]u8,
    transactions_root: [32]u8,
    receipts_root: [32]u8,
    logs_bloom: [256]u8,
    prev_randao: ?[32]u8,
    block_number: i64,
    gas_limit: i64,
    gas_used: u64,
    timestamp: i64,
    extra_data: []const u8,
    mix_hash: u256,
    nonce: [8]u8,
    base_fee_per_gas: ?u256,
    withdrawals_root: ?[32]u8,
    blob_gas_used: ?u64,
    excess_blob_gas: ?u64,
};

const Block = struct {
    header: Header,
};

test "deserialize a shanghai block" {
    var b: Block = undefined;

    const rlp_bytes = @embedFile("testdata/shanghai_block_1.rlp");
    _ = try deserialize(Block, std.testing.allocator, rlp_bytes[0..], &b);
}

test "detects an invalid length serialization" {
    var b: Block = undefined;

    // removed part of the *header* payload but other fields are
    // still present.
    const rlp_bytes = @embedFile("testdata/faulty_shanghai_block.rlp");
    _ = try expectError(error.InvalidSerializedLength, deserialize(Block, std.testing.allocator, rlp_bytes[0..], &b));
}

test "access list empty" {
    const StrippedTxn = struct {
        access_list: []struct {
            address: [20]u8,
            storage_keys: [][32]u8,
        },
    };

    var buf: [128]u8 = undefined;
    const rlp = try std.fmt.hexToBytes(&buf, "c1c0");

    var out: StrippedTxn = undefined;
    _ = try deserialize(StrippedTxn, std.testing.allocator, rlp, &out);
}

test "deserialize a byte slice" {
    var buf: [128]u8 = undefined;
    const rlp = try std.fmt.hexToBytes(&buf, "940000000000000000000000000000000000001210");
    var out: []const u8 = undefined;

    _ = try deserialize([]const u8, std.testing.allocator, rlp, &out);
    try std.testing.expect(std.mem.eql(u8, "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x12\x10", out));
}

test "deserialize a pointer to an integer" {
    const rlp = [_]u8{ 138, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    var out: *u256 = undefined;
    _ = try deserialize(*u256, std.testing.allocator, &rlp, &out);
    defer std.testing.allocator.destroy(out);
    _ = try std.testing.expectEqual(out.*, 0x0102030405060708090a);
}

test "deserialize a 55-byte string (0xb7 prefix)" {
    // 0xb7 == 0x80 + 55 is the short-string header for a 55-byte payload.
    // we treated 0xb7 as the long-string sentinel (size_size=0),
    // silently returning an empty string instead of the 55-byte payload.
    const data = [_]u8{0xAB} ** 55;
    var rlp_bytes: [56]u8 = undefined;
    rlp_bytes[0] = 0xb7;
    @memcpy(rlp_bytes[1..], &data);

    var out: []const u8 = undefined;
    const consumed = try deserialize([]const u8, std.testing.allocator, &rlp_bytes, &out);
    try std.testing.expectEqual(56, consumed);
    try std.testing.expectEqualSlices(u8, &data, out);
}

test "deserialize [N]u8 from empty byte string must fail" {
    // 0x80 is the RLP encoding of an empty byte string (zero length).
    // Attempting to decode it into a [20]u8 must return an error, not
    // silently produce 20 bytes of garbage/undefined.
    const rlp_bytes = [_]u8{0x80};
    var out: [20]u8 = undefined;
    try std.testing.expectError(error.RlpInvalidLength, deserialize([20]u8, undefined, &rlp_bytes, &out));
}

test "short list header bound check (0xc0..0xf7)" {
    // The short-list bound check in sizeAndDataOffset must use 0xc0
    // (rlpListShortHeader) as the lower sentinel, not 0xf7.
    // With the old buggy 0xf7 sentinel, headers in [0xc0, 0xf7) would be
    // misclassified as long byte-strings (size_size = header - 0xb7)
    // instead of short lists (size = header - 0xc0).
    //
    // 0xc5 = 0xc0 + 5 → short list with 5 bytes of payload.
    // 0x84 = 0x80 + 4 → byte string of 4 bytes (encodes u32 = 0xdeadbeef).
    // 0xde, 0xad, 0xbe, 0xef → the integer value.
    const rlp = [_]u8{ 0xc5, 0x84, 0xde, 0xad, 0xbe, 0xef };
    var out: []u32 = undefined;
    const consumed = try deserialize([]u32, std.testing.allocator, &rlp, &out);
    defer std.testing.allocator.free(out);
    try std.testing.expect(consumed == rlp.len);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), out[0]);
}

test "short list at lower bound 0xc0" {
    // 0xc0 is the smallest valid short-list header (empty list).
    // This exercises the very bottom of the [0xc0, 0xf7] range.
    const rlp = [_]u8{0xc0};
    var out: []u32 = undefined;
    const consumed = try deserialize([]u32, std.testing.allocator, &rlp, &out);
    defer std.testing.allocator.free(out);
    try std.testing.expect(consumed == rlp.len);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "short list at upper bound 0xf7" {
    // 0xf7 is the largest valid short-list header (55 bytes of payload).
    // This exercises the very top of the [0xc0, 0xf7] range.
    var buf: [56]u8 = undefined;
    buf[0] = 0xf7;
    // 55 bytes of payload: 11 x u8 items (each 1 byte, all >= 0x80 so each
    // is a single-byte RLP element).
    for (buf[1..]) |*b| b.* = 0x81;
    const rlp = buf[0..];
    var out: []u8 = undefined;
    const consumed = try deserialize([]u8, std.testing.allocator, rlp, &out);
    defer std.testing.allocator.free(out);
    try std.testing.expect(consumed == rlp.len);
    try std.testing.expectEqual(@as(usize, 55), out.len);
    for (out) |b| {
        try std.testing.expectEqual(@as(u8, 0x81), b);
    }
}

test "deserialize slice of non-byte types from short RLP list" {
    // 0xc5 = 0xc0 + 5: short list header with 5 bytes of payload.
    // 0x84 = 0x80 + 4: byte string of 4 bytes (encoding of u32 = 0xdeadbeef).
    // 0xde, 0xad, 0xbe, 0xef: the value.
    // This exercises the code path at the list-header guard for slices of
    // non-byte types. The guard must use rlpListShortHeader (0xc0) as the
    // lower bound; using 0xf7 would reject valid short list headers in [0xc0,
    // 0xf7) as NotAnRLPList.
    const rlp = [_]u8{ 0xc5, 0x84, 0xde, 0xad, 0xbe, 0xef };
    var out: []u32 = undefined;
    const consumed = try deserialize([]u32, std.testing.allocator, &rlp, &out);
    defer std.testing.allocator.free(out);
    try std.testing.expect(consumed == rlp.len);
    try std.testing.expect(out.len == 1);
    try std.testing.expect(out[0] == 0xdeadbeef);
}

test "deserialize empty slice of non-byte types from short RLP list" {
    // 0xc0 is the RLP encoding of an empty list (short form).
    // This exercises the lower bound of the list-header guard: the check
    // must accept 0xc0 itself (using <=, not <).
    const rlp = [_]u8{0xc0};
    var out: []u32 = undefined;
    const consumed = try deserialize([]u32, std.testing.allocator, &rlp, &out);
    defer std.testing.allocator.free(out);
    try std.testing.expect(consumed == rlp.len);
    try std.testing.expect(out.len == 0);
}

test "deserialize integer from empty RLP value (regression: no OOB panic)" {
    // 0x80 is the RLP encoding of an empty byte string == integer 0. Its value
    // region is zero-length, so decoding it into a u8 used to run
    // `readInt(u8, payload[0..1])` on an empty slice and panic with
    // "index out of bounds". It must instead 0-extend to 0.
    {
        const rlp = [_]u8{0x80};
        var out: u8 = 0xaa;
        const consumed = try deserialize(u8, std.testing.allocator, &rlp, &out);
        try std.testing.expectEqual(@as(usize, 1), consumed);
        try std.testing.expectEqual(@as(u8, 0), out);
    }
    // 0xc0 is an empty list; its value region is also zero-length. This is the exact
    // devp2p Disconnect `[]` payload that crashed a real decode.
    {
        const rlp = [_]u8{0xc0};
        var out: u8 = 0xaa;
        const consumed = try deserialize(u8, std.testing.allocator, &rlp, &out);
        try std.testing.expectEqual(@as(usize, 1), consumed);
        try std.testing.expectEqual(@as(u8, 0), out);
    }
    // A value wider than the target type is rejected, not truncated or panicked.
    {
        const rlp = [_]u8{ 0x82, 0x03, 0xe8 }; // 2-byte string 0x03e8
        var out: u8 = 0;
        try std.testing.expectError(error.RlpIntPayloadTooLong, deserialize(u8, std.testing.allocator, &rlp, &out));
    }
}

test "deserialize a boolean" {
    // Canonical encodings: 0x80 (empty byte string) is false, 0x01 is true.
    {
        var out: bool = true;
        try expect(try deserialize(bool, std.testing.allocator, &[_]u8{0x80}, &out) == 1);
        try expect(out == false);
    }
    {
        var out: bool = false;
        try expect(try deserialize(bool, std.testing.allocator, &[_]u8{0x01}, &out) == 1);
        try expect(out == true);
    }
    // A bare 0x00 is a one-byte string, not the canonical false, but it is
    // accepted for compatibility with encoders that emit it.
    {
        var out: bool = true;
        try expect(try deserialize(bool, std.testing.allocator, &[_]u8{0x00}, &out) == 1);
        try expect(out == false);
    }
    // Anything else is not a boolean.
    var out: bool = undefined;
    try expectError(error.RlpInvalidBoolean, deserialize(bool, std.testing.allocator, &[_]u8{0x02}, &out));
    try expectError(error.RlpInvalidBoolean, deserialize(bool, std.testing.allocator, &[_]u8{ 0x82, 0x00, 0x01 }, &out));
    try expectError(error.RlpPayloadTooShort, deserialize(bool, std.testing.allocator, &[_]u8{}, &out));
}

test "deserialize a struct inside a struct with booleans" {
    // Booleans inside a container: the field must consume exactly one byte so
    // the fields after it stay aligned.
    const S = struct { a: bool, b: u16, c: bool };
    var list = ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    const in = S{ .a = false, .b = 0xabcd, .c = true };
    try serialize(S, std.testing.allocator, in, &list);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xc5, 0x80, 0x82, 0xab, 0xcd, 0x01 }, list.items);

    var out: S = undefined;
    const consumed = try deserialize(S, std.testing.allocator, list.items, &out);
    try expect(consumed == list.items.len);
    try std.testing.expectEqual(in, out);
}

test "deserialize a struct rejects malformed input" {
    const S = struct { a: u8 };
    var out: S = undefined;

    // Nothing to read at all.
    try expectError(error.EOF, deserialize(S, std.testing.allocator, &[_]u8{}, &out));

    // A struct is a list; a byte-string header cannot start one.
    try expectError(error.NotAnRLPList, deserialize(S, std.testing.allocator, &[_]u8{0x82}, &out));
    try expectError(error.NotAnRLPList, deserialize(S, std.testing.allocator, &[_]u8{0x00}, &out));

    // The list header claims more payload than the buffer holds.
    try expectError(error.InvalidSerializedLength, deserialize(S, std.testing.allocator, &[_]u8{0xc4}, &out));
}

test "deserialize a slice rejects a non-list header" {
    var out: []u32 = undefined;
    // 0x82 is a byte-string header; a slice of non-byte items needs a list.
    try expectError(error.NotAnRLPList, deserialize([]u32, std.testing.allocator, &[_]u8{ 0x82, 0x01, 0x02 }, &out));
}

test "deserialize rejects a list whose element overruns the payload" {
    // 0xc3: list with 3 bytes of payload. The single element claims a 4-byte
    // string (0x84) but only 2 bytes follow, so counting the items must fail
    // instead of walking off the end.
    const rlp = [_]u8{ 0xc3, 0x84, 0xde, 0xad };
    var out: []u32 = undefined;
    try expectError(error.RlpPayloadTooShort, deserialize([]u32, std.testing.allocator, &rlp, &out));
}

test "deserialize rejects a truncated length field" {
    // 0xb9 announces a 2-byte length, but only one byte follows.
    var out: []const u8 = undefined;
    try expectError(error.RlpPayloadTooShort, deserialize([]const u8, std.testing.allocator, &[_]u8{ 0xb9, 0x01 }, &out));

    // Same for the long-list header: 0xf9 announces two length bytes.
    var list_out: []u32 = undefined;
    try expectError(error.RlpPayloadTooShort, deserialize([]u32, std.testing.allocator, &[_]u8{ 0xf9, 0x01 }, &list_out));
}

test "deserialize rejects a byte string that overruns the buffer" {
    // 0x85 claims 5 bytes of payload, only 2 are present.
    var out: []const u8 = undefined;
    try expectError(error.RlpPayloadTooShort, deserialize([]const u8, std.testing.allocator, &[_]u8{ 0x85, 0x01, 0x02 }, &out));

    // Same guard for fixed-size arrays.
    var ary: [5]u8 = undefined;
    try expectError(error.RlpPayloadTooShort, deserialize([5]u8, std.testing.allocator, &[_]u8{ 0x85, 0x01, 0x02 }, &ary));

    // A payload that fits the buffer but not the array is a length mismatch.
    try expectError(error.RlpInvalidLength, deserialize([5]u8, std.testing.allocator, &[_]u8{ 0x82, 0x01, 0x02 }, &ary));
}

test "deserialize into a mutable byte slice copies the payload" {
    // A const slice aliases the input; a mutable one must own its bytes, so it
    // has to survive the source buffer being overwritten.
    var src = [_]u8{ 0x83, 'a', 'b', 'c' };
    var out: []u8 = undefined;
    const consumed = try deserialize([]u8, std.testing.allocator, &src, &out);
    defer std.testing.allocator.free(out);
    try expect(consumed == src.len);
    @memset(&src, 0);
    try std.testing.expectEqualSlices(u8, "abc", out);
}

test "deserialize an optional held by an empty list header" {
    // Both 0x80 and 0xc0 mark an absent optional, and each consumes one byte.
    var out: ?u32 = 42;
    try expect(try deserialize(?u32, std.testing.allocator, &[_]u8{0xc0}, &out) == 1);
    try expect(out == null);

    // Inside a container, the placeholder must keep the following fields aligned.
    const S = struct { a: ?u32, b: u8 };
    var s: S = undefined;
    const consumed = try deserialize(S, std.testing.allocator, &[_]u8{ 0xc2, 0x80, 0x07 }, &s);
    try expect(consumed == 3);
    try expect(s.a == null);
    try expect(s.b == 7);
}

test "deserialize rejects unsupported types" {
    var f: f32 = undefined;
    try expectError(error.UnsupportedType, deserialize(f32, std.testing.allocator, &[_]u8{0x80}, &f));

    // Fixed-size arrays of non-byte items are not handled.
    var ary: [2]u16 = undefined;
    try expectError(error.UnsupportedType, deserialize([2]u16, std.testing.allocator, &[_]u8{0xc0}, &ary));
}

test "round-trip a nested structure" {
    const Inner = struct { flag: bool, id: u64 };
    const Outer = struct {
        name: []const u8,
        inner: Inner,
        hash: [32]u8,
        tail: ?u32,
    };

    var list = ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    const in = Outer{
        .name = "a name long enough to push the payload past fifty-five bytes",
        .inner = .{ .flag = true, .id = 0xdead_beef_dead_beef },
        .hash = [_]u8{0xab} ** 32,
        .tail = 0x1234,
    };
    try serialize(Outer, std.testing.allocator, in, &list);

    var out: Outer = undefined;
    const consumed = try deserialize(Outer, std.testing.allocator, list.items, &out);
    try expect(consumed == list.items.len);
    try expect(eql(u8, in.name, out.name));
    try std.testing.expectEqual(in.inner, out.inner);
    try std.testing.expectEqual(in.hash, out.hash);
    try std.testing.expectEqual(in.tail, out.tail);
}
