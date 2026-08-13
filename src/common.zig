const std = @import("std");

pub const rlpByteListShortHeader = 0x80;
pub const rlpByteListLongHeader = 0xb7;
pub const rlpListShortHeader = 0xc0;
pub const rlpListLongHeader = 0xf7;
pub const rlpShortMaxLen = 55;

// When reading the payload, leading zeros are removed, so there might be a
// difference in byte-size between the number of bytes and the target integer.
// If so, the bytes have to be extracted into a temporary value.
pub inline fn safeReadSliceIntBig(comptime T: type, payload: []const u8, out: *T) !void {
    // RLP integers are big-endian with leading zero bytes omitted, so the value
    // may be shorter than @sizeOf(T) (readVarInt 0-extends) or empty (=> 0). A value
    // wider than the target type is an overflow and rejected rather than truncated.
    // NOTE: this is only working if the uint's byte length is a power of 2.
    if (payload.len > @sizeOf(T)) return error.RlpIntPayloadTooLong;
    out.* = std.mem.readVarInt(T, payload, .big);
}

// Returns the size of the payload as well as the offset to the
// start of the actual data.
pub fn sizeAndDataOffset(payload: []const u8) !struct { size: usize, offset: usize } {
    var size: usize = undefined;
    var offset: usize = undefined;

    if (payload.len == 0) {
        return error.RlpPayloadTooShort;
    }

    if (payload[0] < rlpByteListShortHeader) {
        offset = 0;
        size = 1;
    } else if (payload[0] <= rlpByteListLongHeader) {
        size = @as(usize, payload[0] - rlpByteListShortHeader);
        offset = 1;
    } else if (payload[0] < rlpListShortHeader) {
        const size_size = @as(usize, payload[0] - rlpByteListLongHeader);

        if (payload.len < 1 + size_size) {
            return error.RlpPayloadTooShort;
        }

        try safeReadSliceIntBig(usize, payload[1 .. 1 + size_size], &size);
        offset = 1 + size_size;
    } else if (payload[0] <= rlpListLongHeader) {
        size = @as(usize, payload[0] - rlpListShortHeader);
        offset = 1;
    } else {
        const size_size = @as(usize, payload[0] - rlpListLongHeader);

        if (payload.len < 1 + size_size) {
            return error.RlpPayloadTooShort;
        }

        try safeReadSliceIntBig(usize, payload[1 .. 1 + size_size], &size);
        offset = 1 + size_size;
    }
    // Callers rely on `payload.len - offset` not underflowing when
    // bounds-checking the payload, so this must hold on every path above.
    std.debug.assert(offset <= payload.len);

    return .{ .size = size, .offset = offset };
}
