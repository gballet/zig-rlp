const std = @import("std");
const testing = std.testing;
const ArrayList = std.ArrayList;

fn serialize(comptime T: type, data: T, list: *ArrayList(u8)) !void {
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
                try list.append(128 + data.len);
                _ = try list.writer().write(data[0..]);
            } else {
                // This only works for short byte sequences
                const size_index = list.items.len;
                try list.append(0);
                for (data) |item| {
                    try serialize(info.Array.child, item, list);
                }
                list.items[size_index] = 128 + @truncate(u8, list.items.len - size_index - 1);
            }
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
    const src16 = [_]u16{ 0xabcd, 0xef01 };
    try serialize([2]u16, src16, &list);
    const expected16 = [_]u8{ 134, 130, 0xab, 0xcd, 130, 0xef, 0x01 };
    try testing.expect(std.mem.eql(u8, list.items[0..], expected16[0..]));
}
