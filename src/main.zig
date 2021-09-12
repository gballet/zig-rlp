const std = @import("std");
const testing = std.testing;
const ArrayList = std.ArrayList;
pub const deserialize = @import("deserialize.zig").deserialize;

pub fn serialize(comptime T: type, data: T, list: *ArrayList(u8)) !void {
    const info = @typeInfo(T);
    return switch (info) {
        .Int => switch (data) {
            0...127 => list.append(@truncate(u8, data)),

            else => {
                try list.append(128 + @sizeOf(T));
                try list.writer().writeIntBig(T, data);
            },
        },
        .Array => {
            // shortcut for byte lists
            if (@sizeOf(info.Array.child) == 1) {
                if (data.len < 56) {
                    try list.append(128 + data.len);
                } else {
                    comptime var length_length = 0;
                    comptime {
                        var l = @sizeOf(T);
                        while (l != 0) : (l >>= 8) {
                            length_length += 1;
                        }
                    }
                    try list.append(183 + length_length);
                    comptime var i = 0;
                    comptime var length = @sizeOf(T);
                    inline while (i < length_length) : (i += 1) {
                        try list.append(@truncate(u8, length));
                        length >>= 8;
                    }
                }
                _ = try list.writer().write(data[0..]);
            } else {
                var tlist = ArrayList(u8).init(testing.allocator);
                defer tlist.deinit();
                for (data) |item| {
                    try serialize(info.Array.child, item, &tlist);
                }

                if (tlist.items.len < 56) {
                    try list.append(128 + @truncate(u8, tlist.items.len));
                } else {
                    const index = list.items.len;
                    try list.append(0);
                    var length = tlist.items.len;
                    var length_length: u8 = 0;
                    while (length != 0) : (length >>= 8) {
                        try list.append(@truncate(u8, length));
                        length_length += 1;
                    }

                    list.items[index] = 183 + length_length;
                }
                _ = try list.writer().write(tlist.items);
            }
        },
        .Struct => |sinfo| {
            var tlist = ArrayList(u8).init(testing.allocator);
            defer tlist.deinit();
            inline for (sinfo.fields) |field| {
                try serialize(field.field_type, @field(data, field.name), &tlist);
            }
            if (tlist.items.len < 56) {
                try list.append(192 + @truncate(u8, tlist.items.len));
            } else {
                const index = list.items.len;
                try list.append(0);
                var length = tlist.items.len;
                var length_length: u8 = 0;
                while (length != 0) : (length >>= 8) {
                    try list.append(@truncate(u8, length));
                    length_length += 1;
                }

                list.items[index] = 183 + length_length;
            }
            _ = try list.writer().write(tlist.items);
        },
        .Pointer => |ptr| {
            switch (ptr.size) {
                .Slice => {
                    // Simple case: string
                    if (@sizeOf(ptr.child) == 1) {
                        try list.append(128 + @truncate(u8, data.len));
                        _ = try list.writer().write(data);
                    } else {
                        var tlist = ArrayList(u8).init(testing.allocator);
                        defer tlist.deinit();
                        for (data) |item| {
                            try serialize(ptr.child, item, &tlist);
                        }

                        if (tlist.items.len < 56) {
                            try list.append(192 + @truncate(u8, tlist.items.len));
                        } else {
                            const index = list.items.len;
                            try list.append(0);
                            var length = tlist.items.len;
                            var length_length: u8 = 0;
                            while (length != 0) : (length >>= 8) {
                                try list.append(@truncate(u8, length));
                                length_length += 1;
                            }

                            list.items[index] = 183 + length_length;
                        }
                        _ = try list.writer().write(tlist.items);
                    }
                },
                .One => {
                    try serialize(ptr.child, data.*, list);
                },
                else => return error.UnsupportedType,
            }
        },
        .Null => {
            try list.append(0x80);
        },
        .Bool => {
            try list.append(if (data) 1 else 0);
        },
        else => return error.UnsupportedType,
    };
}

test "serialize an integer" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();
    try serialize(u8, 42, &list);
    const expected1 = [_]u8{42};
    try testing.expect(std.mem.eql(u8, list.items[0..], expected1[0..]));

    list.clearRetainingCapacity();
    try serialize(u8, 129, &list);
    const expected2 = [_]u8{ 129, 129 };
    try testing.expect(std.mem.eql(u8, list.items[0..], expected2[0..]));

    list.clearRetainingCapacity();
    try serialize(u8, 128, &list);
    const expected3 = [_]u8{ 129, 128 };
    try testing.expect(std.mem.eql(u8, list.items[0..], expected3[0..]));

    list.clearRetainingCapacity();
    try serialize(u16, 0xabcd, &list);
    const expected4 = [_]u8{ 130, 0xab, 0xcd };
    try testing.expect(std.mem.eql(u8, list.items[0..], expected4[0..]));

    // Check that multi-byte values that are < 128 also serialize as a
    // single byte integer.
    list.clearRetainingCapacity();
    try serialize(u16, 42, &list);
    try testing.expect(std.mem.eql(u8, list.items[0..], expected1[0..]));

    list.clearRetainingCapacity();
    try serialize(u32, 0xdeadbeef, &list);
    const expected6 = [_]u8{ 132, 0xde, 0xad, 0xbe, 0xef };
    try testing.expect(std.mem.eql(u8, list.items[0..], expected6[0..]));
}

test "serialize a byte array" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();
    const src = [_]u8{ 1, 2, 3, 4 };
    try serialize([4]u8, src, &list);
    const expected = [_]u8{ 132, 1, 2, 3, 4 };
    try testing.expect(std.mem.eql(u8, list.items[0..], expected[0..]));

    list.clearRetainingCapacity();
    const src8x58 = [_]u8{0xab} ** 58;
    try serialize([58]u8, src8x58, &list);
    const expected8x58 = [_]u8{ 0xb8, 0x3a } ++ [_]u8{0xab} ** 58;
    try testing.expect(std.mem.eql(u8, list.items[0..], expected8x58[0..]));

    list.clearRetainingCapacity();
    const src8x1K = [_]u8{0xab} ** 1024;
    try serialize(@TypeOf(src8x1K), src8x1K, &list);
    const expected8x1K = [_]u8{ 0xb9, 0x00, 0x04 } ++ [_]u8{0xab} ** 1024;
    try testing.expect(std.mem.eql(u8, list.items[0..], expected8x1K[0..]));
}

test "serialize a u16 array" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();
    const src16 = [_]u16{ 0xabcd, 0xef01 };
    try serialize([2]u16, src16, &list);
    const expected16 = [_]u8{ 134, 130, 0xab, 0xcd, 130, 0xef, 0x01 };
    try testing.expect(std.mem.eql(u8, list.items[0..], expected16[0..]));

    list.clearRetainingCapacity();
    const src16x1K = [_]u16{0xabcd} ** 1024;
    try serialize(@TypeOf(src16x1K), src16x1K, &list);
    const expected16x1K = [_]u8{ 0xb9, 0, 0x0C } ++ [_]u8{ 130, 0xab, 0xcd } ** 1024;
    try testing.expect(std.mem.eql(u8, list.items[0..], expected16x1K[0..]));
}

test "serialize a string" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();
    try serialize([]const u8, "hello", &list);
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
    try serialize(Person, jc, &list);
    const expected = [_]u8{ 0xc2 + jc.name.len, 123, 128 + jc.name.len } ++ jc.name;
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
    try serialize(Person, jc, &list);
    const expected = [_]u8{ 0xc2 + jc.name.len, 123, 128 + jc.name.len } ++ jc.name;
    try testing.expect(std.mem.eql(u8, list.items[0..], expected[0..]));
}

test "serialize a boolean" {
    var list = ArrayList(u8).init(testing.allocator);
    defer list.deinit();
    try serialize(bool, false, &list);
    var expected = [_]u8{0};
    try testing.expect(std.mem.eql(u8, list.items[0..], expected[0..]));

    list.clearRetainingCapacity();
    expected[0] = 1;
    try serialize(bool, true, &list);
    try testing.expect(std.mem.eql(u8, list.items[0..], expected[0..]));
}
