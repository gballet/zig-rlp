//! Benchmark workload for comparing builds with poop:
//!
//!     zig build bench
//!     poop './rlp-bench-before serialize' 'zig-out/bin/rlp-bench serialize'
//!
//! Usage: rlp-bench [all|serialize|deserialize] [iterations]
//!
//! The workload is a mainnet-shaped block: a header, 200 legacy transactions
//! with 100-byte calldata, and 2 uncle headers (~44.6 KB encoded). It covers
//! structs, slices of structs, byte arrays, byte slices and wide integers.

const std = @import("std");
const ArrayList = std.array_list.Managed;

const rlp = @import("rlp.zig");

const Tx = struct {
    nonce: u64,
    gas_price: u256,
    gas: u64,
    to: [20]u8,
    value: u256,
    data: []const u8,
    v: u64,
    r: u256,
    s: u256,
};

const Header = struct {
    parent_hash: [32]u8,
    uncle_hash: [32]u8,
    coinbase: [20]u8,
    state_root: [32]u8,
    tx_root: [32]u8,
    receipt_root: [32]u8,
    bloom: [256]u8,
    difficulty: u256,
    number: u64,
    gas_limit: u64,
    gas_used: u64,
    time: u64,
    extra: []const u8,
    mix: [32]u8,
    nonce: [8]u8,
};

const Block = struct {
    header: Header,
    txs: []Tx,
    uncles: []Header,
};

const tx_count = 200;
const default_iterations = 5000;

const Mode = enum { all, serialize, deserialize };

fn usage() noreturn {
    std.debug.print("usage: rlp-bench [all|serialize|deserialize] [iterations]\n", .{});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const mode: Mode = if (args.next()) |arg| std.meta.stringToEnum(Mode, arg) orelse usage() else .all;
    const iterations: usize = if (args.next()) |arg| std.fmt.parseInt(usize, arg, 10) catch usage() else default_iterations;
    if (args.next() != null) usage();

    const gpa = init.gpa;

    const calldata: [100]u8 = @splat(0xaa);
    var txs: [tx_count]Tx = undefined;
    for (&txs, 0..) |*tx, i| tx.* = .{
        .nonce = 1000 + i,
        .gas_price = 1 << 40,
        .gas = 21000,
        .to = @splat(0x11),
        .value = 1 << 70,
        .data = &calldata,
        .v = 27,
        .r = (@as(u256, 1) << 255) + i,
        .s = (@as(u256, 1) << 254) + i,
    };
    const header: Header = .{
        .parent_hash = @splat(1),
        .uncle_hash = @splat(2),
        .coinbase = @splat(3),
        .state_root = @splat(4),
        .tx_root = @splat(5),
        .receipt_root = @splat(6),
        .bloom = @splat(7),
        .difficulty = 1 << 60,
        .number = 1 << 24,
        .gas_limit = 30_000_000,
        .gas_used = 12_000_000,
        .time = 1_700_000_000,
        .extra = "extra",
        .mix = @splat(8),
        .nonce = @splat(9),
    };
    var uncles: [2]Header = .{ header, header };
    const block: Block = .{ .header = header, .txs = &txs, .uncles = &uncles };

    var out = ArrayList(u8).init(gpa);
    defer out.deinit();
    try rlp.serialize(Block, gpa, block, &out);

    if (mode != .deserialize) {
        for (0..iterations) |_| {
            out.clearRetainingCapacity();
            try rlp.serialize(Block, gpa, block, &out);
            std.mem.doNotOptimizeAway(out.items.ptr);
        }
    }

    if (mode != .serialize) {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var decoded: Block = undefined;
        for (0..iterations) |_| {
            _ = arena.reset(.retain_capacity);
            const consumed = try rlp.deserialize(Block, arena.allocator(), out.items, &decoded);
            if (consumed != out.items.len) return error.TrailingBytes;
            std.mem.doNotOptimizeAway(&decoded);
        }
    }
}
