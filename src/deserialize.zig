const std = @import("std");
const expect = std.testing.expect;
const eql = std.mem.eql;
const readIntSliceBig = std.mem.readIntSliceBig;

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

pub fn deserialize(comptime T: type, serialized: []const u8, out: *T) !void {
    const info = @typeInfo(T);
    return switch (info) {
        .Int => {
            if (serialized[0] < 0x80) {
                out.* = serialized[0];
            } else if (serialized[0] < 0xb7) {
                // Recover the payload size from the header.
                const size = @as(usize, serialized[0] - 0x80);

                // Special case: empty value, return 0
                if (size == 0) {
                    return;
                }

                if (size > serialized.len + 1) {
                    return error.EOF;
                }
                safeReadSliceIntBig(T, serialized[1 .. 1 + size], out);
            } else {
                const size_size = @as(usize, serialized[0] - 0xb7);
                const size = readIntSliceBig(usize, serialized[1 .. 1 + size_size]);
                safeReadSliceIntBig(T, serialized[1 + size_size ..], out);
            }
        },
        else => return error.UnsupportedType,
    };
}

test "deserialize an integer" {
    const su8lo = [_]u8{42};
    var u8lo: u8 = undefined;
    try deserialize(u8, su8lo[0..], &u8lo);
    try expect(u8lo == 42);

    const su8hi = [_]u8{ 129, 192 };
    var u8hi: u8 = undefined;
    try deserialize(u8, su8hi[0..], &u8hi);
    try expect(u8hi == 192);

    const su16small = [_]u8{ 129, 192 };
    var u16small: u16 = undefined;
    try deserialize(u16, su16small[0..], &u16small);
    try expect(u16small == 192);

    const su16long = [_]u8{ 130, 192, 192 };
    var u16long: u16 = undefined;
    try deserialize(u16, su16long[0..], &u16long);
    try expect(u16long == 0xc0c0);
}
