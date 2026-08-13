const std = @import("std");
const testing = std.testing;
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const hasFn = std.meta.hasFn;

pub const deserialize = @import("deserialize.zig").deserialize;
const common = @import("common.zig");
const sizeAndDataOffset = common.sizeAndDataOffset;

fn writeLengthLength(length: usize, list: *ArrayList(u8)) !u8 {
    var enc_length_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &enc_length_buf, length, .big);
    const enc_length = std.mem.trimStart(u8, &enc_length_buf, &[_]u8{0});
    try list.appendSlice(enc_length);
    return @as(u8, @intCast(enc_length.len));
}

pub const SerializationError = error{
    UnsupportedType,
    OutOfMemory,
    EmptyRawValue,
};

const rlpByteListShortHeader = common.rlpByteListShortHeader;
const rlpByteListLongHeader = common.rlpByteListLongHeader;
const rlpListShortHeader = common.rlpListShortHeader;
const rlpListLongHeader = common.rlpListLongHeader;
const rlpShortMaxLen = common.rlpShortMaxLen;

pub fn serialize(comptime T: type, allocator: Allocator, data: T, list: *ArrayList(u8)) SerializationError!void {
    if (comptime hasFn(T, "encodeToRLP")) {
        return data.encodeToRLP(allocator, list);
    }
    const info = @typeInfo(T);
    return switch (info) {
        .int => {
            // RLP only supports unsigned integers. Signed types are not allowed.
            comptime switch (@typeInfo(T).int.signedness) {
                .unsigned => {},
                .signed => @compileError("RLP does not support signed integers; use an unsigned type instead"),
            };
            comptime {
                const bits = @typeInfo(T).int.bits;
                if (bits < 8 or !std.math.isPowerOfTwo(bits)) {
                    @compileError("RLP integers must have a power-of-two bit width of at least 8; got " ++ @typeName(T));
                }
            }
            return switch (data) {
                0 => list.append(rlpByteListShortHeader),
                1...127 => list.append(@truncate(data)),

                else => {
                    // write integer to temp buffer so that it can
                    // be left-trimmed.
                    var int_buf: [@sizeOf(T)]u8 = undefined;
                    std.mem.writeInt(T, &int_buf, data, .big);
                    const payload = std.mem.trimStart(u8, &int_buf, &[_]u8{0});

                    // copy final header + trimmed data
                    try list.append(@as(u8, @truncate(128 + tlist.items.len - start_offset)));
                    _ = try list.appendSlice(tlist.items[start_offset..]);
                    if (payload.len <= rlpShortMaxLen) {
                        try list.append(rlpByteListShortHeader + @as(u8, @intCast(payload.len)));
                    } else {
                        const header_offset = list.items.len;
                        try list.append(0);
                        const length_length = try writeLengthLength(payload.len, list);
                        list.items[header_offset] = rlpByteListLongHeader + length_length;
                    }
                    try list.appendSlice(payload);
                },
            };
        },
        .array => {
            // shortcut for byte lists
            if (@sizeOf(info.array.child) == 1) {
                switch (data.len) {
                    0 => try list.append(128),
                    1 => if (data[0] >= 128) {
                        try list.append(129);
                    },
                    2...55 => try list.append(128 + data.len),
                    else => {
                        comptime var length_length = 0;
                        comptime {
                            var l = @sizeOf(T);
                            while (l != 0) : (l >>= 8) {
                                length_length += 1;
                            }
                        }

                        try list.append(183 + length_length);
                        _ = try writeLengthLength(@sizeOf(T), list);
                    },
                }
                _ = try list.appendSlice(data[0..]);
            } else {
                var tlist = ArrayList(u8).init(allocator);
                defer tlist.deinit();
                for (data) |item| {
                    try serialize(info.array.child, allocator, item, &tlist);
                }

                if (tlist.items.len < 56) {
                    try list.append(192 + @as(u8, @truncate(tlist.items.len)));
                } else {
                    const index = list.items.len;
                    try list.append(0);
                    const length = tlist.items.len;

                    const length_length = try writeLengthLength(length, list);
                    list.items[index] = 247 + length_length;
                }
                _ = try list.appendSlice(tlist.items);
            }
        },
        .@"struct" => |sinfo| {
            var tlist = ArrayList(u8).init(allocator);
            defer tlist.deinit();
            inline for (sinfo.fields) |field| {
                try serialize(field.type, allocator, @field(data, field.name), &tlist);
            }
            if (tlist.items.len < 56) {
                try list.append(192 + @as(u8, @truncate(tlist.items.len)));
            } else {
                const index = list.items.len;
                try list.append(0);
                const length_length = try writeLengthLength(tlist.items.len, list);
                list.items[index] = 247 + length_length;
            }
            _ = try list.appendSlice(tlist.items);
        },
        .pointer => |ptr| {
            switch (ptr.size) {
                .slice => {
                    // Simple case: string
                    if (@sizeOf(ptr.child) == 1) {
                        switch (data.len) {
                            0 => try list.append(128),
                            // if data.len == 1 and data[0] < 128, don't write the header
                            // the write after this switch will add the unprefixed data.
                            1 => if (data[0] >= 128) try list.append(129),
                            2...55 => try list.append(128 + @as(u8, @truncate(data.len))),
                            else => {
                                const header_offset = list.items.len;
                                try list.append(0); // reserve space for the size header
                                const length_length = try writeLengthLength(data.len, list);
                                list.items[header_offset] = 183 + length_length;
                            },
                        }
                        _ = try list.appendSlice(data);
                    } else {
                        var tlist = ArrayList(u8).init(allocator);
                        defer tlist.deinit();
                        for (data) |item| {
                            try serialize(ptr.child, allocator, item, &tlist);
                        }

                        if (tlist.items.len < 56) {
                            try list.append(192 + @as(u8, @truncate(tlist.items.len)));
                        } else {
                            const index = list.items.len;
                            try list.append(0);
                            const length_length: u8 = try writeLengthLength(tlist.items.len, list);

                            list.items[index] = 247 + length_length;
                        }
                        _ = try list.appendSlice(tlist.items);
                    }
                },
                .one => {
                    try serialize(ptr.child, allocator, data.*, list);
                },
                else => return error.UnsupportedType,
            }
        },
        .optional => |opt| {
            if (data == null) {
                try list.append(0x80);
            } else {
                try serialize(opt.child, allocator, data.?, list);
            }
        },
        .null => {
            try list.append(0x80);
        },
        .bool => {
            try list.append(if (data) 1 else rlpByteListShortHeader);
        },
        else => return error.UnsupportedType,
    };
}

pub const RawRLPValue = union(enum) {
    value: []const u8, // already-encoded RLP; emitted verbatim
    list: []const RawRLPValue, // children wrapped with an RLP list header

    pub fn encodeToRLP(self: RawRLPValue, allocator: Allocator, list: *ArrayList(u8)) !void {
        return switch (self) {
            .value => |v| {
                // An empty raw value has no RLP encoding (even the empty byte
                // string is 0x80), and emitting nothing would corrupt any
                // enclosing list: the header is computed over the body that
                // silently lost an element.
                if (v.len == 0) return error.EmptyRawValue;
                try list.appendSlice(v);
            },
            .list => |v| {
                try serialize([]const RawRLPValue, allocator, v, list);
            },
        };
    }

    pub fn decodeFromRLP(self: *RawRLPValue, _: Allocator, serialized: []const u8) !usize {
        const r = try sizeAndDataOffset(serialized);
        if (r.size > serialized.len - r.offset) return error.RlpPayloadTooShort;
        const consumed = r.offset + r.size;
        self.* = .{ .value = serialized[0..consumed] };
        return consumed;
    }
};

test "serialize an integer" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();
    try serialize(u8, testing.allocator, 42, &list);
    const expected1 = [_]u8{42};
    try testing.expect(std.mem.eql(u8, list.items[0..], expected1[0..]));

    list.clearRetainingCapacity();
    try serialize(u8, testing.allocator, 129, &list);
    const expected2 = [_]u8{ 129, 129 };
    try testing.expect(std.mem.eql(u8, list.items[0..], expected2[0..]));

    list.clearRetainingCapacity();
    try serialize(u8, testing.allocator, 128, &list);
    const expected3 = [_]u8{ 129, 128 };
    try testing.expect(std.mem.eql(u8, list.items[0..], expected3[0..]));

    list.clearRetainingCapacity();
    try serialize(u16, testing.allocator, 0xabcd, &list);
    const expected4 = [_]u8{ 130, 0xab, 0xcd };
    try testing.expect(std.mem.eql(u8, list.items[0..], expected4[0..]));

    // Check that multi-byte values that are < 128 also serialize as a
    // single byte integer.
    list.clearRetainingCapacity();
    try serialize(u16, testing.allocator, 42, &list);
    try testing.expect(std.mem.eql(u8, list.items[0..], expected1[0..]));

    list.clearRetainingCapacity();
    try serialize(u32, testing.allocator, 0xdeadbeef, &list);
    const expected6 = [_]u8{ 132, 0xde, 0xad, 0xbe, 0xef };
    try testing.expect(std.mem.eql(u8, list.items[0..], expected6[0..]));
}

test "serialize a byte array" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();
    const src = [_]u8{ 1, 2, 3, 4 };
    try serialize([4]u8, testing.allocator, src, &list);
    const expected = [_]u8{ 132, 1, 2, 3, 4 };
    try testing.expect(std.mem.eql(u8, list.items[0..], expected[0..]));

    list.clearRetainingCapacity();
    const src8x58 = [_]u8{0xab} ** 58;
    try serialize([58]u8, testing.allocator, src8x58, &list);
    const expected8x58 = [_]u8{ 0xb8, 0x3a } ++ [_]u8{0xab} ** 58;
    try testing.expect(std.mem.eql(u8, list.items[0..], expected8x58[0..]));

    list.clearRetainingCapacity();
    const src8x1K = [_]u8{0xab} ** 1024;
    try serialize(@TypeOf(src8x1K), testing.allocator, src8x1K, &list);
    const expected8x1K = [_]u8{ 0xb9, 0x04, 0x00 } ++ [_]u8{0xab} ** 1024;
    try testing.expect(std.mem.eql(u8, list.items[0..], expected8x1K[0..]));
}

test "serialize a u16 array" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();
    const src16 = [_]u16{ 0xabcd, 0xef01 };
    try serialize([2]u16, testing.allocator, src16, &list);
    const expected16 = [_]u8{ 198, 130, 0xab, 0xcd, 130, 0xef, 0x01 };
    try testing.expect(std.mem.eql(u8, list.items[0..], expected16[0..]));

    list.clearRetainingCapacity();
    const src16x1K = [_]u16{0xabcd} ** 1024;
    try serialize(@TypeOf(src16x1K), testing.allocator, src16x1K, &list);
    const expected16x1K = [_]u8{ 0xf9, 0x0C, 0 } ++ [_]u8{ 130, 0xab, 0xcd } ** 1024;
    try testing.expect(std.mem.eql(u8, list.items[0..], expected16x1K[0..]));
}

test "serialize a string" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();
    try serialize([]const u8, testing.allocator, "hello", &list);
    const expected = [_]u8{ 133, 'h', 'e', 'l', 'l', 'o' };
    try testing.expect(std.mem.eql(u8, list.items[0..], expected[0..]));
}

test "serialize a struct" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();
    const Person = struct {
        age: u8,
        name: []const u8,
    };
    const jc = Person{ .age = 123, .name = "Jeanne Calment" };
    try serialize(Person, testing.allocator, jc, &list);
    const expected = [_]u8{ 0xc2 + jc.name.len, 123, 128 + jc.name.len } ++ jc.name;
    try testing.expect(std.mem.eql(u8, list.items[0..], expected[0..]));
}

test "serialize a struct with serialized length > 56" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();
    const Person = struct {
        age: u8,
        name: []const u8,
    };
    const dt = Person{ .age = 24, .name = "Daenerys Stormborn of the House Targaryen, First of Her Name, the Unburnt, Queen of the Andals and the First Men, Khaleesi of the Great Grass Sea, Breaker of Chains, and Mother of Dragons" };
    try serialize(Person, testing.allocator, dt, &list);
    const expected = [_]u8{ 0xf8, @as(u8, dt.name.len) + 3, 24, 184, @as(u8, dt.name.len) } ++ dt.name;
    try testing.expect(std.mem.eql(u8, list.items[0..], expected[0..]));
}

test "serialize a struct with functions" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();
    const Person = struct {
        age: u8,
        name: []const u8,

        pub fn sayHello() void {
            std.debug.print("hello", .{});
        }
    };
    const jc = Person{ .age = 123, .name = "Jeanne Calment" };
    try serialize(Person, testing.allocator, jc, &list);
    const expected = [_]u8{ 0xc2 + jc.name.len, 123, 128 + jc.name.len } ++ jc.name;
    try testing.expect(std.mem.eql(u8, list.items[0..], expected[0..]));
}

test "serialize a boolean" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    try serialize(bool, testing.allocator, false, &list);
    try testing.expectEqualSlices(u8, &[_]u8{0x80}, list.items);

    list.clearRetainingCapacity();
    try serialize(bool, testing.allocator, true, &list);
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, list.items);
}

test "round-trip a boolean" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    for ([_]bool{ false, true }) |v| {
        list.clearRetainingCapacity();
        try serialize(bool, testing.allocator, v, &list);
        var out: bool = undefined;
        const consumed = try deserialize(bool, testing.allocator, list.items, &out);
        try testing.expectEqual(list.items.len, consumed);
        try testing.expectEqual(v, out);
    }
}

const RLPEncodablePerson = struct {
    name: []const u8,
    age: u8,

    pub fn encodeToRLP(self: RLPEncodablePerson, allocator: Allocator, list: *ArrayList(u8)) !void {
        _ = allocator;
        _ = self;
        return list.append(42);
    }
};

test "custom serializer" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();
    const jdoe = RLPEncodablePerson{ .name = "John Doe", .age = 57 };
    try serialize(RLPEncodablePerson, testing.allocator, jdoe, &list);
    try testing.expect(list.items.len == 1);
    try testing.expect(list.items[0] == 42);
}

test "ensure an int is tightly packed" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    const i: u256 = 0x1234;
    const expected = [_]u8{ 0x82, 0x12, 0x34 };
    try serialize(u256, testing.allocator, i, &list);
    try testing.expect(std.mem.eql(u8, list.items[0..], expected[0..]));
}

test "zero" {
    var out = ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();

    try serialize(u8, std.testing.allocator, 0, &out);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x80}, out.items);
}

test "access list filled" {
    const AccessListItem = struct {
        address: [20]u8,
        storage_keys: [][32]u8,
    };
    const StrippedTxn = struct {
        access_list: []AccessListItem,
    };

    var buf: [128]u8 = undefined;
    const rlp = try std.fmt.hexToBytes(&buf, "f83af838f7940000000000000000000000000000000000001210e1a00000000000000000000000000000000000000000000000000000000000000203");
    var out: StrippedTxn = undefined;
    _ = try deserialize(StrippedTxn, testing.allocator, rlp, &out);

    const expected_address = [_]u8{0} ** 18 ++ [_]u8{ 0x12, 0x10 };
    try testing.expectEqual(out.access_list[0].address, expected_address);

    const expected_access = [_]u8{0} ** 30 ++ [_]u8{ 2, 3 };
    try testing.expectEqual(out.access_list[0].storage_keys[0], expected_access);

    testing.allocator.free(out.access_list[0].storage_keys);
    testing.allocator.free(out.access_list);
}

test "one byte slice" {
    var out = ArrayList(u8).init(testing.allocator);
    defer out.deinit();
    const bytes = [_]u8{0x00};

    try serialize([]const u8, std.testing.allocator, &bytes, &out);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x00}, out.items);
}

test "one byte slicei with value == 128" {
    var out = ArrayList(u8).init(testing.allocator);
    defer out.deinit();
    const bytes = [_]u8{0x80};

    try serialize([]const u8, std.testing.allocator, &bytes, &out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x80 }, out.items);
}

test "one byte slicei with value > 128" {
    var out = ArrayList(u8).init(testing.allocator);
    defer out.deinit();
    const bytes = [_]u8{0xff};

    try serialize([]const u8, std.testing.allocator, &bytes, &out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0xff }, out.items);
}

test "raw rlp value is verbatim, list wraps" {
    const allocator = std.testing.allocator;
    var out = ArrayList(u8).init(allocator);
    defer out.deinit();

    // .value holds already-encoded RLP and is emitted as-is.
    try serialize(RawRLPValue, allocator, RawRLPValue{ .value = &([_]u8{0x85} ++ "hello".*) }, &out);
    try testing.expectEqualSlices(u8, &([_]u8{0x85} ++ "hello".*), out.items);

    // .list wraps its raw children with a freshly computed list header.
    out.clearRetainingCapacity();
    try serialize(RawRLPValue, allocator, RawRLPValue{ .list = &[_]RawRLPValue{
        .{ .value = &([_]u8{0x85} ++ "hello".*) },
        .{ .value = &([_]u8{0x85} ++ "world".*) },
    } }, &out);
    try testing.expectEqualSlices(u8, &([_]u8{0xcc} ++ [_]u8{0x85} ++ "hello".* ++ [_]u8{0x85} ++ "world".*), out.items);
}

test "raw rlp captures items verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // [ "hello", "world", [ "nested" ] ] in canonical RLP.
    const encoded = [_]u8{0xd4} ++
        [_]u8{0x85} ++ "hello".* ++
        [_]u8{0x85} ++ "world".* ++
        [_]u8{ 0xc7, 0x86 } ++ "nested".*;

    // As a single value: the whole item is captured verbatim (not split).
    var whole: RawRLPValue = undefined;
    try testing.expectEqual(encoded.len, try deserialize(RawRLPValue, a, &encoded, &whole));
    try testing.expectEqualSlices(u8, &encoded, whole.value);

    // As a slice: the list is split one level, each element captured verbatim
    // (the nested list is NOT descended into).
    var items: []RawRLPValue = undefined;
    try testing.expectEqual(encoded.len, try deserialize([]RawRLPValue, a, &encoded, &items));
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualSlices(u8, &([_]u8{0x85} ++ "hello".*), items[0].value);
    try testing.expectEqualSlices(u8, &([_]u8{ 0xc7, 0x86 } ++ "nested".*), items[2].value);

    // Re-encoding the elements reproduces the original list.
    var reencoded = ArrayList(u8).init(a);
    try serialize([]const RawRLPValue, a, items, &reencoded);
    try testing.expectEqualSlices(u8, &encoded, reencoded.items);
}

test "raw rlp decode rejects a length that overflows usize" {
    // 0xbf = 0xb7 + 8: a byte-string header carrying an 8-byte length field
    // whose value is 0xffff_ffff_ffff_ffff. The header itself consumes 9
    // bytes, so computing `r.offset + r.size` unchecked wraps usize: a panic
    // on untrusted input in safe modes, and in ReleaseFast the wrapped sum
    // slips past the bounds check and yields a bogus 8-byte value. The size
    // must be checked against the remaining buffer before adding the offset.
    const evil = [_]u8{ 0xbf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    var out: RawRLPValue = undefined;
    try testing.expectError(error.RlpPayloadTooShort, deserialize(RawRLPValue, std.testing.allocator, &evil, &out));
}

test "raw rlp rejects an empty raw value" {
    const allocator = testing.allocator;
    var out = ArrayList(u8).init(allocator);
    defer out.deinit();

    // Top-level: there is nothing to emit, and emitting nothing is not RLP.
    try testing.expectError(error.EmptyRawValue, serialize(RawRLPValue, allocator, RawRLPValue{ .value = &[_]u8{} }, &out));

    // Nested in a list: previously the list header was computed over the
    // body with the empty element silently dropped (c1 01 for two elements,
    // which decodes back to one). The child serialization hits the same check.
    try testing.expectError(error.EmptyRawValue, serialize(RawRLPValue, allocator, RawRLPValue{ .list = &[_]RawRLPValue{
        .{ .value = &[_]u8{} },
        .{ .value = &[_]u8{0x01} },
    } }, &out));
}

test "serialize an integer whose payload exceeds 55 bytes" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    // 55 significant bytes is the last size that fits the short form.
    const short_max: u512 = (@as(u512, 1) << 440) - 1;
    try serialize(u512, testing.allocator, short_max, &list);
    try testing.expectEqualSlices(u8, &([_]u8{0xb7} ++ [_]u8{0xff} ** 55), list.items);

    list.clearRetainingCapacity();
    const long_min: u512 = (@as(u512, 1) << 448) - 1;
    try serialize(u512, testing.allocator, long_min, &list);
    try testing.expectEqualSlices(u8, &([_]u8{ 0xb8, 0x38 } ++ [_]u8{0xff} ** 56), list.items);

    list.clearRetainingCapacity();
    try serialize(u512, testing.allocator, std.math.maxInt(u512), &list);
    try testing.expectEqualSlices(u8, &([_]u8{ 0xb8, 0x40 } ++ [_]u8{0xff} ** 64), list.items);

    list.clearRetainingCapacity();
    try serialize(u4096, testing.allocator, std.math.maxInt(u4096), &list);
    try testing.expectEqualSlices(u8, &([_]u8{ 0xb9, 0x02, 0x00 } ++ [_]u8{0xff} ** 512), list.items);
}

test "round-trip integers wider than 55 bytes" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    inline for (.{ u512, u1024 }) |T| {
        inline for (.{ std.math.maxInt(T), (@as(T, 1) << (@bitSizeOf(T) - 1)), @as(T, 0) }) |v| {
            list.clearRetainingCapacity();
            try serialize(T, testing.allocator, v, &list);
            var out: T = undefined;
            const consumed = try deserialize(T, testing.allocator, list.items, &out);
            try testing.expectEqual(list.items.len, consumed);
            try testing.expectEqual(@as(T, v), out);
        }
    }
}

test "serialize a pointer to a single item" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    const v: u16 = 0xabcd;
    try serialize(*const u16, testing.allocator, &v, &list);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0xab, 0xcd }, list.items);

    list.clearRetainingCapacity();
    const Pair = struct { a: u8, b: u8 };
    const pair = Pair{ .a = 1, .b = 2 };
    try serialize(*const Pair, testing.allocator, &pair, &list);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xc2, 0x01, 0x02 }, list.items);
}

test "serialize a slice of non-byte items with a payload over 55 bytes" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    const backing = [_]u16{0xabcd} ** 20;
    const items: []const u16 = &backing;
    try serialize([]const u16, testing.allocator, items, &list);
    try testing.expectEqualSlices(u8, &([_]u8{ 0xf8, 0x3c } ++ [_]u8{ 0x82, 0xab, 0xcd } ** 20), list.items);

    list.clearRetainingCapacity();
    const big_backing = [_]u16{0xabcd} ** 100;
    const big_items: []const u16 = &big_backing;
    try serialize([]const u16, testing.allocator, big_items, &list);
    try testing.expectEqualSlices(u8, &([_]u8{ 0xf9, 0x01, 0x2c } ++ [_]u8{ 0x82, 0xab, 0xcd } ** 100), list.items);
}

test "serialize an empty byte array and single high bytes" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    try serialize([0]u8, testing.allocator, [_]u8{}, &list);
    try testing.expectEqualSlices(u8, &[_]u8{0x80}, list.items);

    list.clearRetainingCapacity();
    try serialize([1]u8, testing.allocator, [_]u8{0x7f}, &list);
    try testing.expectEqualSlices(u8, &[_]u8{0x7f}, list.items);

    list.clearRetainingCapacity();
    try serialize([1]u8, testing.allocator, [_]u8{0x80}, &list);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x80 }, list.items);

    list.clearRetainingCapacity();
    try serialize([1]u8, testing.allocator, [_]u8{0xff}, &list);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0xff }, list.items);
}

test "serialize an empty slice and an empty struct" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    const empty: []const u8 = &[_]u8{};
    try serialize([]const u8, testing.allocator, empty, &list);
    try testing.expectEqualSlices(u8, &[_]u8{0x80}, list.items);

    list.clearRetainingCapacity();
    const empty_ints: []const u16 = &[_]u16{};
    try serialize([]const u16, testing.allocator, empty_ints, &list);
    try testing.expectEqualSlices(u8, &[_]u8{0xc0}, list.items);

    list.clearRetainingCapacity();
    try serialize(struct {}, testing.allocator, .{}, &list);
    try testing.expectEqualSlices(u8, &[_]u8{0xc0}, list.items);
}

test "serialize rejects unsupported types" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    try testing.expectError(error.UnsupportedType, serialize(f32, testing.allocator, 1.5, &list));
    try testing.expectError(error.UnsupportedType, serialize(enum { a, b }, testing.allocator, .a, &list));

    const backing = [_]u8{ 1, 2, 3 };
    const many: [*]const u8 = &backing;
    try testing.expectError(error.UnsupportedType, serialize([*]const u8, testing.allocator, many, &list));
}

test "serialize null and a populated optional" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    try serialize(@TypeOf(null), testing.allocator, null, &list);
    try testing.expectEqualSlices(u8, &[_]u8{0x80}, list.items);

    list.clearRetainingCapacity();
    try serialize(?u16, testing.allocator, 0xabcd, &list);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0xab, 0xcd }, list.items);
}

test "round-trip random integers of every supported width" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    var prng = std.Random.DefaultPrng.init(0x5eed_1234_abcd_0001);
    const random = prng.random();

    inline for (.{ u8, u16, u32, u64, u128, u256, u512, u1024 }) |T| {
        for (0..256) |_| {
            var bytes: [@sizeOf(T)]u8 = undefined;
            random.bytes(&bytes);
            const v = std.mem.readInt(T, &bytes, .big) >> random.int(std.math.Log2Int(T));

            list.clearRetainingCapacity();
            try serialize(T, testing.allocator, v, &list);

            var out: T = undefined;
            const consumed = try deserialize(T, testing.allocator, list.items, &out);
            try testing.expectEqual(list.items.len, consumed);
            try testing.expectEqual(v, out);

            var again = ArrayList(u8).init(testing.allocator);
            defer again.deinit();
            try serialize(T, testing.allocator, out, &again);
            try testing.expectEqualSlices(u8, list.items, again.items);
        }
    }
}

test "round-trip random byte strings across the length boundaries" {
    var prng = std.Random.DefaultPrng.init(0x5eed_1234_abcd_0002);
    const random = prng.random();

    var buf: [512]u8 = undefined;
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    for (0..301) |len| {
        const payload = buf[0..len];
        random.bytes(payload);

        list.clearRetainingCapacity();
        try serialize([]const u8, testing.allocator, payload, &list);

        var out: []const u8 = undefined;
        const consumed = try deserialize([]const u8, testing.allocator, list.items, &out);
        try testing.expectEqual(list.items.len, consumed);
        try testing.expectEqualSlices(u8, payload, out);
    }
}
