const std = @import("std");
const serialize = @import("main.zig").serialize;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const eql = std.mem.eql;
const readIntSliceBig = std.mem.readIntSliceBig;
const ArrayList = std.ArrayList;
const hasFn = std.meta.trait.hasFn;

const implementsDecodeRLP = hasFn("decodeRLP");

const rlpByteListShortHeader = 128;
const rlpByteListLongHeader = 183;
const rlpListShortHeader = 192;
const rlpListLongHeader = 247;

// When reading the payload, leading zeros are removed, so there might be a
// difference in byte-size between the number of bytes and the target integer.
// If so, the bytes have to be extracted into a temporary value.
inline fn safeReadSliceIntBig(comptime T: type, payload: []const u8, out: *T) void {
    // compile time constat to activate the first branch. If
    // @sizeOf(T) > 1, then it is possible (and necessary) to
    // shift temp.
    const log2tgt1 = (@sizeOf(T) > 1);
    if (log2tgt1 and @sizeOf(T) > payload.len) {
        var temp: T = 0;
        var i: usize = 0;
        while (i < payload.len) : (i += 1) {
            temp = @shlExact(temp, 8); // payload.len < @sizeOf(T), should not overflow
            temp |= @as(T, payload[i]);
        }
        out.* = temp;
    } else {
        out.* = readIntSliceBig(T, payload[0..]);
    }
}

// Returns the amount of data consumed from `serialized`.
pub fn deserialize(comptime T: type, serialized: []const u8, out: *T) !usize {
    if (comptime implementsDecodeRLP(T)) {
        return out.decodeRLP(serialized);
    }
    const info = @typeInfo(T);
    return switch (info) {
        .Int => {
            if (serialized[0] < rlpByteListShortHeader) {
                out.* = serialized[0];
                return 1; // consumed the byte
            } else if (serialized[0] < rlpByteListLongHeader) {
                // Recover the payload size from the header.
                const size = @as(usize, serialized[0] - rlpByteListShortHeader);

                // Special case: empty value, return 0
                if (size == 0) {
                    return 1; // consumed the header
                }

                if (size > serialized.len + 1) {
                    return error.EOF;
                }
                safeReadSliceIntBig(T, serialized[1 .. 1 + size], out);
                return 1 + size;
            } else {
                const size_size = @as(usize, serialized[0] - rlpByteListLongHeader);
                const size = readIntSliceBig(usize, serialized[1 .. 1 + size_size]);
                safeReadSliceIntBig(T, serialized[1 + size_size ..], out);
                return 1 + size_size + size;
            }
        },
        .Struct => |struc| {
            if (serialized.len == 0) {
                return error.EOF;
            }
            // A structure is encoded as a list, not
            // a bitstring.
            if (serialized[0] < rlpListShortHeader) {
                return error.NotAnRLPList;
            }
            var size: usize = undefined;
            var offset: usize = 1;
            if (serialized[0] < rlpListLongHeader) {
                size = @as(usize, serialized[0] - rlpListShortHeader);
            } else {
                const size_size = @as(usize, serialized[0] - rlpListLongHeader);
                offset += size_size;
                size = readIntSliceBig(usize, serialized[1..]) / std.math.pow(usize, 256, 8 - size_size);
            }
            // limit of the struct's rlp encoding inside the larger buffer
            const limit = offset + size;
            if (limit > serialized.len) {
                return error.InvalidSerializedLength;
            }

            inline for (struc.fields) |field| {
                if (offset > limit) {
                    std.debug.print("offset overflow for payload offset={} limit={} field name={s} type={any}\n", .{ offset, limit, field.name, field.type });
                    return error.OffsetOverflow;
                }
                offset += try deserialize(field.type, serialized[offset..limit], &@field(out.*, field.name));
            }

            return offset;
        },
        .Pointer => |ptr| switch (ptr.size) {
            .Slice => if (ptr.child == u8) {
                if (serialized[0] < rlpByteListShortHeader) {
                    out.* = serialized[0..1];
                    return 1;
                } else if (serialized[0] < rlpByteListLongHeader) {
                    const size = @as(usize, serialized[0] - rlpByteListShortHeader);
                    out.* = serialized[1 .. 1 + size];
                    return 1 + size;
                } else {
                    const size_size = @as(usize, serialized[0] - rlpByteListLongHeader);
                    const size = readIntSliceBig(usize, serialized[1 .. 1 + size_size]);
                    out.* = serialized[1 + size_size .. 1 + size_size + size];
                    return 1 + size + size_size;
                }
            } else {
                if (serialized[0] < rlpListShortHeader) {
                    return error.NotAnRLPList;
                }

                var size: usize = undefined;
                var offset: usize = undefined;

                if (serialized[0] < rlpListLongHeader) {
                    size = @as(usize, serialized[0] - rlpListShortHeader);
                    offset = 1;
                } else {
                    const size_size = @as(usize, serialized[0] - rlpListLongHeader);
                    size = readIntSliceBig(usize, serialized[1..]) / std.math.pow(usize, 256, 8 - size_size);
                    offset = 1 + size_size;
                }

                var end = offset + size;
                var i: usize = 0;
                while (offset < end) : (i += 1) {
                    offset += try deserialize(ptr.child, serialized[offset..], &out.*[i]);
                }

                return offset + size;
            },
            else => return error.UnSupportedType,
        },
        .Array => |ary| if (@sizeOf(ary.child) == 1) {
            if (serialized[0] < rlpByteListShortHeader) {
                out.*[0] = serialized[0];
                return 1;
            } else if (serialized[0] < rlpByteListLongHeader) {
                const size = @as(usize, serialized[0] - rlpByteListShortHeader);
                // The target might be larger than the payload, as 0s are not
                // stored in the RLP encoding.
                if (size > out.len)
                    return error.InvalidArrayLength;

                std.mem.copy(u8, out.*[0..], serialized[1 .. 1 + size]);
                return 1 + size;
            } else {
                const size_size = @as(usize, serialized[0] - rlpByteListLongHeader);
                var padded_bytes: [8]u8 = [_]u8{0} ** 8;
                @memcpy(padded_bytes[8 - size_size ..], serialized[1 .. 1 + size_size]);
                const size = readIntSliceBig(usize, &padded_bytes);
                if (size != out.len) {
                    return error.InvalidArrayLength;
                }
                std.mem.copy(u8, out.*[0..], serialized[1 + size_size .. 1 + size_size + size]);
                return 1 + size + size_size;
            }
        } else return error.UnsupportedType,
        .Optional => |opt| {
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
            if (serialized.len == 0 or serialized[0] == rlpByteListShortHeader or serialized[0] == rlpListLongHeader) {
                out.* = null;
                // 0 if serialized was empty, one in the case of an empty list
                return serialized.len;
            } else {
                var t: opt.child = undefined;
                const offset = try deserialize(opt.child, serialized[0..], &t);
                out.* = t;
                return offset;
            }
        },
        else => return error.UnsupportedType,
    };
}

test "deserialize an integer" {
    var consumed: usize = 0;

    const su8lo = [_]u8{42};
    var u8lo: u8 = undefined;
    consumed = try deserialize(u8, su8lo[0..], &u8lo);
    try expect(u8lo == 42);
    try expect(consumed == 1);

    const su8hi = [_]u8{ 129, 192 };
    var u8hi: u8 = undefined;
    consumed = try deserialize(u8, su8hi[0..], &u8hi);
    try expect(u8hi == 192);
    try expect(consumed == su8hi.len);

    const su16small = [_]u8{ 129, 192 };
    var u16small: u16 = undefined;
    consumed = try deserialize(u16, su16small[0..], &u16small);
    try expect(u16small == 192);
    try expect(consumed == su16small.len);

    const su16long = [_]u8{ 130, 192, 192 };
    var u16long: u16 = undefined;
    consumed = try deserialize(u16, su16long[0..], &u16long);
    try expect(u16long == 0xc0c0);
    try expect(consumed == su16long.len);
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
    const consumed = try deserialize(Person, list.items[0..], &p);
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
    const consumed = try deserialize([]const u8, list.items[0..], &s);
    try expect(eql(u8, str, s));
    try expect(consumed == list.items.len);
}

test "deserialize a byte array" {
    const expected = [_]u8{ 1, 2, 3 };
    var list = ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try serialize(@TypeOf(expected), std.testing.allocator, expected, &list);
    var out: [3]u8 = undefined;
    const consumed = try deserialize([3]u8, list.items[0..], &out);
    try expect(eql(u8, expected[0..], out[0..]));
    try expect(consumed == list.items.len);
}

const RLPDecodablePerson = struct {
    name: []const u8,
    age: u8,

    pub fn decodeRLP(self: *RLPDecodablePerson, serialized: []const u8) !usize {
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
    const consumed = try deserialize(RLPDecodablePerson, serialized[0..], &person);
    try expect(person.age == serialized[0]);
    try expect(consumed == 1);
}

test "deserialize an optional" {
    var list = ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    var x: ?u32 = null;

    try serialize(?u32, std.testing.allocator, x, &list);
    var y: ?u32 = undefined;
    _ = try deserialize(?u32, list.items, &y);
    try expect(y == null);

    list.clearAndFree();
    x = 32;
    var z: ?u32 = undefined;
    try serialize(?u32, std.testing.allocator, x, &list);
    _ = try deserialize(?u32, list.items, &z);
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
    _ = try deserialize(structWithTrailingOptionalFields, serialized[0..], &mystruct);
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
    prev_randao: [32]u8,
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
    _ = try deserialize(Block, rlp_bytes[0..], &b);
}

test "detects an invalid length serialization" {
    var b: Block = undefined;

    // removed part of the *header* payload but other fields are
    // still present.
    const rlp_bytes = @embedFile("testdata/faulty_shanghai_block.rlp");
    _ = try expectError(error.InvalidSerializedLength, deserialize(Block, rlp_bytes[0..], &b));
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
    _ = try deserialize(StrippedTxn, rlp, &out);
}
