const std = @import("std");
const testing = std.testing;
const ArrayList = std.ArrayList;

fn serialize(comptime T: type, data: T, list: *ArrayList(u8)) !void {
    const info = @typeInfo(T);
    return switch (info) {
        .Int => switch (data) {
            0...127 => list.append(data),

            else => {
                try list.append(128 + @sizeOf(T));
                try list.writer().writeIntBig(T, data);
            },
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
    testing.expect(std.mem.eql(u8, try serialize(u16, 0xabcd, &list), [_]u8{ 129, 0xab, 0xcd }));

    list.clearRetainingCapacity();
    testing.expect(std.mem.eql(u8, try serialize(u32, 0xdeadbeef, &list), [_]u8{ 129, 0xde, 0xad, 0xbe, 0xef }));
}
