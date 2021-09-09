const std = @import("std");
const expect = std.testing.expect;
const eql = std.mem.eql;

pub fn deserialize(comptime T: type, serialized: []const u8, out: *T) !void {
    const info = @typeInfo(T);
    return switch (info) {
        .Int => {
            if (serialized[0] < 0x80) {
                out.* = serialized[0];
            } else if (serialized[0] < 0xb7) {
                const size = @as(usize, serialized[0] - 0x80);
                if (size > serialized.len + 1) {
                    return error.EOF;
                }
                out.* = std.mem.readIntSliceBig(T, serialized[1..]);
            } else {}
        },
        else => return error.UnsupportedType,
    };
}

test "deserialize an integer" {
    const su8lo = [_]u8{42};
    var u8lo: u8 = undefined;
    try deserialize(u8, su8lo[0..], &u8lo);
    try expect(u8lo == 42);

    const su8hi = [_]u8{ 128, 192 };
    var u8hi: u8 = undefined;
    try deserialize(u8, su8hi[0..], &u8hi);
    try expect(u8hi == 192);
}
