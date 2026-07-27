//! Zero-copy RLP inspection.
const std = @import("std");

pub const Kind = enum { string, list };

pub const Error = error{
    Empty,
    Truncated,
    LengthTooLarge,
};

pub const Item = struct {
    kind: Kind,
    payload: []const u8,
    whole: []const u8,
    pub fn iterator(item: Item) error{NotAList}!Iterator {
        if (item.kind != .list) return error.NotAList;
        return .{ .rest = item.payload };
    }

    pub fn at(item: Item, index: usize) (Error || error{NotAList})!?Item {
        var it = try item.iterator();
        var i: usize = 0;
        while (try it.next()) |elem| : (i += 1) {
            if (i == index) return elem;
        }
        return null;
    }
};

pub const Decoded = struct { item: Item, rest: []const u8 };

fn lengthOfLength(bytes: []const u8) Error!usize {
    var v: usize = 0;
    for (bytes) |b| v = (v << 8) | b;
    return v;
}

pub fn firstItem(data: []const u8) Error!Decoded {
    if (data.len == 0) return error.Empty;
    const b0 = data[0];
    if (b0 < 0x80) {
        // A single byte below 0x80 is its own encoding.
        return .{ .item = .{ .kind = .string, .payload = data[0..1], .whole = data[0..1] }, .rest = data[1..] };
    } else if (b0 <= 0xb7) {
        const len: usize = b0 - 0x80;
        if (data.len - 1 < len) return error.Truncated;
        return .{ .item = .{ .kind = .string, .payload = data[1 .. 1 + len], .whole = data[0 .. 1 + len] }, .rest = data[1 + len ..] };
    } else if (b0 <= 0xbf) {
        const len_of_len: usize = b0 - 0xb7;
        if (data.len - 1 < len_of_len) return error.Truncated;
        const len = try lengthOfLength(data[1 .. 1 + len_of_len]);
        if (data.len - 1 - len_of_len < len) return error.Truncated;
        const total = 1 + len_of_len + len;
        return .{ .item = .{ .kind = .string, .payload = data[1 + len_of_len .. total], .whole = data[0..total] }, .rest = data[total..] };
    } else if (b0 <= 0xf7) {
        const len: usize = b0 - 0xc0;
        if (data.len - 1 < len) return error.Truncated;
        return .{ .item = .{ .kind = .list, .payload = data[1 .. 1 + len], .whole = data[0 .. 1 + len] }, .rest = data[1 + len ..] };
    } else {
        const len_of_len: usize = b0 - 0xf7;
        if (data.len - 1 < len_of_len) return error.Truncated;
        const len = try lengthOfLength(data[1 .. 1 + len_of_len]);
        if (data.len - 1 - len_of_len < len) return error.Truncated;
        const total = 1 + len_of_len + len;
        return .{ .item = .{ .kind = .list, .payload = data[1 + len_of_len .. total], .whole = data[0..total] }, .rest = data[total..] };
    }
}

/// Decodes `data` as exactly one item: trailing bytes are an error.
pub fn view(data: []const u8) (Error || error{TrailingBytes})!Item {
    const r = try firstItem(data);
    if (r.rest.len != 0) return error.TrailingBytes;
    return r.item;
}

pub const Iterator = struct {
    rest: []const u8,

    pub fn next(it: *Iterator) Error!?Item {
        if (it.rest.len == 0) return null;
        const r = try firstItem(it.rest);
        it.rest = r.rest;
        return r.item;
    }
};

const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqualSlices = std.testing.expectEqualSlices;

fn expectBorrows(buffer: []const u8, slice: []const u8) !void {
    const base = @intFromPtr(buffer.ptr);
    const p = @intFromPtr(slice.ptr);
    try expect(p >= base and p + slice.len <= base + buffer.len);
}

test "inspect: single bytes and the empty string" {
    const lo = try view(&[_]u8{0x2a});
    try expect(lo.kind == .string);
    try expectEqualSlices(u8, &[_]u8{0x2a}, lo.payload);

    const empty = try view(&[_]u8{0x80});
    try expect(empty.kind == .string);
    try expect(empty.payload.len == 0);
}

test "inspect: short and long strings, at both header boundaries" {
    // 0xb7 = short-string header for the maximal 55-byte payload.
    var short: [56]u8 = undefined;
    short[0] = 0xb7;
    @memset(short[1..], 0xab);
    const s = try view(&short);
    try expect(s.kind == .string);
    try expect(s.payload.len == 55);
    try expectBorrows(&short, s.payload);

    // 0xb8 = long-string header, 1 length byte; 56-byte payload.
    var long: [58]u8 = undefined;
    long[0] = 0xb8;
    long[1] = 56;
    @memset(long[2..], 0xcd);
    const l = try view(&long);
    try expect(l.kind == .string);
    try expect(l.payload.len == 56);
    try expectEqualSlices(u8, long[0..], l.whole);
}

test "inspect: short and long lists, empty list" {
    const empty = try view(&[_]u8{0xc0});
    try expect(empty.kind == .list);
    try expect(empty.payload.len == 0);
    var it = try empty.iterator();
    try expect(try it.next() == null);

    // 0xf7 = short-list header for the maximal 55-byte payload.
    var short: [56]u8 = undefined;
    short[0] = 0xf7;
    @memset(short[1..], 0x01); // 55 single-byte elements
    const s = try view(&short);
    try expect(s.kind == .list);
    var n: usize = 0;
    var sit = try s.iterator();
    while (try sit.next()) |elem| : (n += 1) {
        try expect(elem.kind == .string);
    }
    try expect(n == 55);

    // 0xf8 = long-list header, 1 length byte.
    var long: [58]u8 = undefined;
    long[0] = 0xf8;
    long[1] = 56;
    @memset(long[2..], 0x02);
    const l = try view(&long);
    try expect(l.kind == .list);
    try expect(l.payload.len == 56);
}

test "inspect: firstItem returns the remaining bytes" {
    // "cat", then "dog", as two consecutive items.
    const data = [_]u8{ 0x83, 'c', 'a', 't', 0x83, 'd', 'o', 'g' };
    const first = try firstItem(&data);
    try expectEqualSlices(u8, "cat", first.item.payload);
    const second = try firstItem(first.rest);
    try expectEqualSlices(u8, "dog", second.item.payload);
    try expect(second.rest.len == 0);

    // view() rejects exactly this.
    try expectError(error.TrailingBytes, view(&data));
}

test "inspect: iterator and at() over a header-like list" {
    // ["cat", "dog", ["nested"], 0x2a]
    const data = [_]u8{
        0xd1, // list, 17 payload bytes
        0x83,
        'c',
        'a',
        't',
        0x83,
        'd',
        'o',
        'g',
        0xc7,
        0x86,
        'n',
        'e',
        's',
        't',
        'e',
        'd',
        0x2a,
    };
    const list = try view(&data);
    try expect(list.kind == .list);

    const dog = (try list.at(1)) orelse return error.TestUnexpectedResult;
    try expectEqualSlices(u8, "dog", dog.payload);
    try expectBorrows(&data, dog.payload);

    const nested = (try list.at(2)) orelse return error.TestUnexpectedResult;
    try expect(nested.kind == .list);
    const inner = (try nested.at(0)) orelse return error.TestUnexpectedResult;
    try expectEqualSlices(u8, "nested", inner.payload);

    const last = (try list.at(3)) orelse return error.TestUnexpectedResult;
    try expectEqualSlices(u8, &[_]u8{0x2a}, last.payload);

    try expect(try list.at(4) == null);
}

test "inspect: strings have no elements" {
    const s = try view(&[_]u8{ 0x83, 'c', 'a', 't' });
    try expectError(error.NotAList, s.iterator());
    try expectError(error.NotAList, s.at(0));
}

test "inspect: malformed input errors instead of crashing" {
    try expectError(error.Empty, firstItem(&.{}));
    // Short string promising more bytes than present.
    try expectError(error.Truncated, view(&[_]u8{ 0x83, 'c', 'a' }));
    // Long string with a truncated length-of-length.
    try expectError(error.Truncated, view(&[_]u8{0xb9}));
    // Long string whose announced length exceeds the input.
    try expectError(error.Truncated, view(&[_]u8{ 0xb9, 0xff, 0xff }));
    // List payload ending mid-element surfaces through the iterator.
    const bad_list = [_]u8{ 0xc2, 0x83, 'c' };
    const l = try view(&bad_list);
    var it = try l.iterator();
    try expectError(error.Truncated, it.next());
    // Length-of-length wider than usize.
    var huge: [11]u8 = undefined;
    huge[0] = 0xbf; // 8 length bytes... (0xb7 + 8)
    @memset(huge[1..], 0xff);
    try expectError(error.Truncated, view(&huge));
}
