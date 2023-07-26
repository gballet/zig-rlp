const std = @import("std");
const serialize = @import("main.zig").serialize;
const expect = std.testing.expect;
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
            inline for (struc.fields) |field| {
                offset += try deserialize(field.type, serialized[offset..], &@field(out.*, field.name));
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
                if (serialized[0] < rlpByteListShortHeader) {
                    return try deserialize(ptr.child, serialized[0..1], &out.*[0]);
                } else if (serialized[0] < rlpByteListLongHeader) {
                    const size = @as(usize, serialized[0] - rlpByteListShortHeader);
                    var i: usize = 0;
                    while (i < size) : (i += 1) {
                        i += try deserialize(ptr.child, serialized[1 + i ..], &out.*[i]);
                    }
                    return 1 + size;
                } else {
                    const size_size = @as(usize, serialized[0] - rlpByteListLongHeader);
                    var size = readIntSliceBig(usize, serialized[1..]) / std.math.pow(usize, 256, 8 - size_size);
                    var i: usize = 0;
                    while (i + 1 < size) : (i += 1) {
                        i += try deserialize(ptr.child, serialized[1 + size_size + i ..], &out.*[i]);
                    }
                    return 1 + size + size_size;
                }
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
            if (serialized[0] == 0x80) {
                out.* = null;
                return 1;
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
    try serialize(Person, jc, &list);
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
    try serialize([]const u8, str, &list);
    var s: []const u8 = undefined;
    const consumed = try deserialize([]const u8, list.items[0..], &s);
    try expect(eql(u8, str, s));
    try expect(consumed == list.items.len);
}

test "deserialize a byte array" {
    const expected = [_]u8{ 1, 2, 3 };
    var list = ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try serialize(@TypeOf(expected), expected, &list);
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

    try serialize(?u32, x, &list);
    var y: ?u32 = undefined;
    _ = try deserialize(?u32, list.items, &y);
    try expect(y == null);

    list.clearAndFree();
    x = 32;
    var z: ?u32 = undefined;
    try serialize(?u32, x, &list);
    _ = try deserialize(?u32, list.items, &z);
    try expect(z.? == x.?);
}
