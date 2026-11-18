const std = @import("std");
const kvs = @import("kvs");
const lib = @import("lib.zig");
const linux = std.os.linux;
const errno = linux.errno;
const Io = std.Io;
const Random = std.Random;
const assert = std.debug.assert;
const mem = std.mem;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const math = std.math;
const heap = std.heap;

const Self = @This();

const key_size: usize = 64;
const value_size: usize = 64;

r_buf: [1]u8 = undefined,
gpa: Allocator,
arena: std.heap.ArenaAllocator,
threaded: Io.Threaded,
workload: Workload,
mapper: OpPermute,
gen: EntryGenerator(key_size, value_size),
out_key: [key_size]u8 = undefined,
out_value: [value_size]u8 = undefined,
inc_value: [value_size]u8 = undefined,
client: kvs.Client,
sock: i32,

const OpPermute = struct {
    const MapFn = fn (OpPermute, usize) callconv(.@"inline") usize;

    /// Provides the initial mapping. Scrambles the range so all outputs are in random order.
    mapper: Feistel,

    // Each mapper is assigned a range it will randomize. That random value from the range will go
    // through the mapper. This guarantees different order for each operation and random key
    // ranges.

    preload_mapper: Feistel,
    warmup_mapper: RangeFeistel,
    measure_mapper: RangeFeistel,

    workload: Workload,

    fn init(workload: Workload) OpPermute {
        const mapper: Feistel = .init(
            workload.seed,
            maxKeys(workload.operation, workload.key_count, workload.requests),
        );

        var preload_mapper: Feistel = undefined;
        var warmup_mapper: RangeFeistel = undefined;
        var measure_mapper: RangeFeistel = undefined;

        switch (workload.operation) {
            .get_hit => {
                preload_mapper = .init(workload.seed +% 1, workload.key_count);
                warmup_mapper = .init(workload.seed +% 2, 0, workload.key_count);
                measure_mapper = .init(workload.seed +% 3, 0, workload.key_count);
            },
            .get_miss => {
                preload_mapper = .init(workload.seed +% 1, workload.key_count);
                warmup_mapper = .init(
                    workload.seed +% 2,
                    workload.key_count,
                    workload.key_count * 2,
                );
                measure_mapper = .init(
                    workload.seed +% 3,
                    workload.key_count,
                    workload.key_count * 2,
                );
            },
            .set_insert => {
                preload_mapper = .init(
                    workload.seed +% 1,
                    workload.key_count - workload.requests,
                );
                warmup_mapper = .init(
                    workload.seed +% 2,
                    workload.key_count - workload.requests,
                    workload.key_count,
                );
                measure_mapper = .init(
                    workload.seed +% 3,
                    workload.key_count,
                    workload.key_count + workload.requests,
                );
            },
            .set_replace => {
                preload_mapper = .init(workload.seed +% 1, workload.key_count);
                warmup_mapper = .init(workload.seed +% 2, 0, workload.key_count);
                measure_mapper = .init(workload.seed +% 3, 0, workload.key_count);
            },
            .delete_hit => {
                preload_mapper = .init(
                    workload.seed +% 1,
                    workload.key_count + workload.requests,
                );
                warmup_mapper = .init(
                    workload.seed +% 2,
                    workload.key_count,
                    workload.key_count + workload.requests,
                );
                measure_mapper = .init(workload.seed +% 3, 0, workload.key_count);
            },
            .delete_miss => {
                preload_mapper = .init(workload.seed +% 1, workload.key_count);
                warmup_mapper = .init(
                    workload.seed +% 2,
                    workload.key_count,
                    workload.key_count * 2,
                );
                measure_mapper = .init(
                    workload.seed +% 2,
                    workload.key_count,
                    workload.key_count * 2,
                );
            },
        }

        return .{
            .mapper = mapper,
            .preload_mapper = preload_mapper,
            .warmup_mapper = warmup_mapper,
            .measure_mapper = measure_mapper,
            .workload = workload,
        };
    }

    inline fn preloadIdx(self: OpPermute, i: usize) usize {
        const idx = self.preload_mapper.value(i);
        return self.mapper.value(idx);
    }

    inline fn warmupIdx(self: OpPermute, i: usize) usize {
        const idx = self.warmup_mapper.value(i);
        return self.mapper.value(idx);
    }

    inline fn measureIdx(self: OpPermute, i: usize) usize {
        const idx = self.measure_mapper.value(i);
        return self.mapper.value(idx);
    }

    fn preloadRange(self: OpPermute) usize {
        return switch (self.workload.operation) {
            .get_hit => self.workload.key_count,
            .get_miss => self.workload.key_count,
            .set_insert => self.workload.key_count - self.workload.requests,
            .set_replace => self.workload.key_count,
            .delete_hit => self.workload.key_count + self.workload.requests,
            .delete_miss => self.workload.key_count,
        };
    }

    fn maxKeys(op: Op, key_count: usize, requests: usize) usize {
        return switch (op) {
            .get_hit => key_count,
            .get_miss => key_count * 2,
            .set_insert => key_count + requests,
            .set_replace => key_count,
            .delete_hit => key_count + requests,
            .delete_miss => key_count * 2,
        };
    }
};

const RangeFeistel = struct {
    f: Feistel,
    offset: usize,

    fn init(seed: u64, start: usize, end: usize) RangeFeistel {
        assert(end >= start);

        return .{
            .f = .init(seed, end - start),
            .offset = start,
        };
    }

    inline fn value(self: RangeFeistel, v: usize) usize {
        return self.f.value(v) + self.offset;
    }
};

// Feistel network using splitmix64 with cycle walking.
const Feistel = struct {
    r_mask: usize,
    n: usize,
    seed: u64,

    fn init(seed: u64, n: usize) Feistel {
        assert(n > 0);

        const r_mask = if (n == 1)
            0
        else blk: {
            var idx = (@bitSizeOf(usize) - 1 - @clz(n - 1));
            idx >>= 1;
            var r_mask = @as(usize, 1) << @intCast(idx);
            r_mask <<= 1;
            r_mask -= 1;

            break :blk r_mask;
        };
        var sm = Random.SplitMix64.init(seed);
        return .{
            .n = n,
            .r_mask = r_mask,
            .seed = sm.next(),
        };
    }

    fn value(self: Feistel, v: usize) usize {
        var block = v;
        while (true) {
            for (0..4) |i| {
                block = self.round(block, i);
            }
            if (block < self.n) {
                return block;
            }
        }
    }

    inline fn round(self: Feistel, block: usize, i: usize) usize {
        const l1 = (self.r_mask & block);
        const r1 = (block >> maskSize(self.r_mask)) ^ self.roundFun(l1, i);
        return r1 | (l1 << @intCast(maskSize(self.r_mask)));
    }

    inline fn roundFun(self: Feistel, ri: usize, n_round: usize) usize {
        var sm = Random.SplitMix64.init(ri ^ n_round ^ self.seed);
        return @truncate(sm.next() & self.r_mask);
    }

    /// Assumes mask doesn't have the msb set.
    inline fn maskSize(mask: usize) u6 {
        return @intCast(@bitSizeOf(usize) - @clz(mask));
    }
};

fn EntryGenerator(k_size: usize, v_size: usize) type {
    return struct {
        prng: Random.Xoshiro256,
        seed: u64,

        fn init(seed: u64) @This() {
            assert(k_size > @sizeOf(u64));
            var sm = Random.SplitMix64.init(seed);
            return .{
                .prng = Random.Xoshiro256.init(seed),
                .seed = sm.next(),
            };
        }

        fn entry(self: *@This(), index: usize, key: []u8, value: []u8) void {
            assert(key.len == k_size);
            assert(value.len == v_size);

            self.prng.seed(self.seed +% index);

            std.mem.writeInt(usize, key[0..@sizeOf(u64)], @intCast(index), .native);
            self.prng.random().bytes(key[@sizeOf(u64)..]);
            self.prng.random().bytes(value);
        }
    };
}

pub const Context = struct {
    workload: Workload,
    cpu: linux.cpu_set_t,
    sock: i32,
    port: u16,
};

pub const Workload = struct {
    operation: Op,
    requests: usize,
    key_count: usize,
    seed: u64,
};

pub const Op = enum(u6) {
    get_hit,
    get_miss,
    set_insert,
    set_replace,
    delete_hit,
    delete_miss,

    pub fn formatted(self: Op) []const u8 {
        return switch (self) {
            .get_hit => "get-hit",
            .get_miss => "get-miss",
            .set_insert => "set-insert",
            .set_replace => "set-replace",
            .delete_hit => "delete-hit",
            .delete_miss => "delete-miss",
        };
    }
};

pub const Message = enum(u8) {
    ready = 0,
    done = 1,
    start = 2,
    err = 3,
    connect = 4,
};

pub const ExitCode = enum(u8) {
    success = 0,
    err = 1,

    pub fn value(self: ExitCode) u8 {
        return @intFromEnum(self);
    }
};

pub fn processMain(arg: usize) callconv(.c) u8 {
    const ctx: *const Context = @ptrFromInt(arg);
    if (processMainTyped(ctx)) |_| {
        return ExitCode.success.value();
    } else |_| {
        return ExitCode.err.value();
    }
}

fn processMainTyped(ctx: *const Context) !void {
    defer lib.closeFdLog(ctx.sock);
    try lib.closeRangeExcluding(ctx.sock);
    try linux.sched_setaffinity(0, &ctx.cpu);

    var addr_buf: [21]u8 = undefined;
    const addr = try std.fmt.bufPrint(&addr_buf, "127.0.0.1:{}", .{ctx.port});

    var lgen: Self = undefined;
    try lgen.init(ctx.workload, addr, ctx.sock);
    defer lgen.deinit();

    try lgen.run();
}

fn init(self: *Self, workload: Workload, addr: []const u8, socket: i32) !void {
    self.gpa = std.heap.smp_allocator;
    self.arena = .init(self.gpa);
    self.threaded = .init(self.gpa, .{});
    self.workload = workload;
    try self.client.init(self.io(), addr, .{ .idle_timeout = .fromSeconds(60), .max_attempts = 1 });
    self.gen = .init(workload.seed);
    self.sock = socket;
    self.mapper = .init(workload);
}

fn deinit(self: *Self) void {
    self.arena.deinit();
}

fn run(self: *Self) !void {
    try self.recvMsg(.connect);

    try self.preload();

    switch (self.workload.operation) {
        .get_hit => try self.getHit(OpPermute.warmupIdx),
        .get_miss => try self.getMiss(OpPermute.warmupIdx),
        .set_insert => try self.setInsert(OpPermute.warmupIdx),
        .set_replace => try self.setReplace(OpPermute.warmupIdx),
        .delete_hit => try self.deleteHit(OpPermute.warmupIdx),
        .delete_miss => try self.deleteMiss(OpPermute.warmupIdx),
    }

    try self.sendMsg(.ready);
    try self.recvMsg(.start);

    switch (self.workload.operation) {
        .get_hit => try self.getHit(OpPermute.measureIdx),
        .get_miss => try self.getMiss(OpPermute.measureIdx),
        .set_insert => try self.setInsert(OpPermute.measureIdx),
        .set_replace => try self.setReplace(OpPermute.measureIdx),
        .delete_hit => try self.deleteHit(OpPermute.measureIdx),
        .delete_miss => try self.deleteMiss(OpPermute.measureIdx),
    }

    try self.sendMsg(.done);
}

fn getHit(self: *Self, mapFn: OpPermute.MapFn) !void {
    var alloc: heap.FixedBufferAllocator = .init(&self.inc_value);

    for (0..self.workload.requests) |i| {
        const idx = mapFn(self.mapper, i);
        self.gen.entry(idx, &self.out_key, &self.out_value);

        var r = try self.client.get(alloc.allocator(), &self.out_key);
        defer r.deinit(alloc.allocator());

        if (r.code != .Ok) {
            std.debug.print("got {t} while doing warmup\n", .{r.code});
            return error.Err;
        }

        if (!mem.eql(u8, r.value, &self.out_value)) {
            std.debug.print(
                "got unexpected value: {s}, expected: {s}\n",
                .{ r.value, &self.out_value },
            );
            return error.Err;
        }
    }
}

fn getMiss(self: *Self, mapFn: OpPermute.MapFn) !void {
    var alloc: heap.FixedBufferAllocator = .init(&self.inc_value);

    for (0..self.workload.requests) |i| {
        const idx = mapFn(self.mapper, i);
        self.gen.entry(idx, &self.out_key, &self.out_value);

        var r = try self.client.get(alloc.allocator(), &self.out_key);
        defer r.deinit(alloc.allocator());

        if (r.code != .NotFound) {
            std.debug.print("got {t} while doing warmup\n", .{r.code});
            return error.Err;
        }
    }
}

fn setInsert(self: *Self, mapFn: OpPermute.MapFn) !void {
    try self.preload();

    for (0..self.workload.requests) |i| {
        const idx = mapFn(self.mapper, i);
        self.gen.entry(idx, &self.out_key, &self.out_value);

        var r = try self.client.set(&self.out_key, &self.out_value);

        if (r.code != .Ok) {
            std.debug.print("got {t} while doing warmup\n", .{r.code});
            return error.Err;
        }
    }
}

fn setReplace(self: *Self, mapFn: OpPermute.MapFn) !void {
    for (0..self.workload.requests) |i| {
        const idx = mapFn(self.mapper, i);
        self.gen.entry(idx, &self.out_key, &self.out_value);

        var r = try self.client.set(&self.out_key, &self.out_value);

        if (r.code != .Ok) {
            std.debug.print("got {t} while doing warmup\n", .{r.code});
            return error.Err;
        }
    }
}

fn deleteHit(self: *Self, mapFn: OpPermute.MapFn) !void {
    for (0..self.workload.requests) |i| {
        const idx = mapFn(self.mapper, i);
        self.gen.entry(idx, &self.out_key, &self.out_value);

        var r = try self.client.del(&self.out_key);

        if (r.code != .Ok) {
            std.debug.print("got {t} while doing warmup\n", .{r.code});
            return error.Err;
        }
    }
}

fn deleteMiss(self: *Self, mapFn: OpPermute.MapFn) !void {
    for (0..self.workload.requests) |i| {
        const idx = mapFn(self.mapper, i);
        self.gen.entry(idx, &self.out_key, &self.out_value);

        var r = try self.client.del(&self.out_key);

        if (r.code != .NotFound) {
            std.debug.print("got {t} while doing warmup\n", .{r.code});
            return error.Err;
        }
    }
}

fn preload(self: *Self) !void {
    assert(key_size >= @sizeOf(u64));
    const range = self.mapper.preloadRange();

    for (0..range) |i| {
        const idx = self.mapper.preloadIdx(i);
        self.gen.entry(idx, &self.out_key, &self.out_value);
        const r = try self.client.set(&self.out_key, &self.out_value);
        if (r.code != .Ok) {
            std.debug.print("got error response from server: {t}\n", .{r.code});
            return error.Err;
        }
    }
}

fn recvMsg(self: *Self, msg: Message) !void {
    try lib.recvAll(self.sock, &self.r_buf);
    const code: Message = @enumFromInt(self.r_buf[0]);
    if (code != msg) {
        std.debug.print("expected {t} message, got {t}\n", .{ msg, code });
        return error.Err;
    }
}

fn sendMsg(self: *Self, msg: Message) !void {
    try lib.sendAll(self.sock, @ptrCast(&@intFromEnum(msg)));
}

fn io(self: *Self) Io {
    return self.threaded.io();
}

test {
    std.testing.refAllDecls(Self);
}

test "entry generator is deterministic" {
    const elem_size: usize = 64;
    const entries: usize = 50;
    var gen: EntryGenerator(elem_size, elem_size) = .init(0);

    var buf: [elem_size * 2 * entries]u8 = undefined;

    var sm = Random.SplitMix64.init(0);

    for (0..entries) |i| {
        gen.entry(
            @truncate(sm.next()),
            buf[i * 2 * elem_size .. (i * 2) * elem_size + elem_size],
            buf[(i * 2) * elem_size + elem_size .. (i * 2 + 2) * elem_size],
        );
    }

    sm.s = 0;

    var key: [elem_size]u8 = undefined;
    var value: [elem_size]u8 = undefined;

    for (0..entries) |i| {
        gen.entry(@truncate(sm.next()), &key, &value);
        try testing.expectEqualSlices(
            u8,
            buf[i * 2 * elem_size .. (i * 2) * elem_size + elem_size],
            &key,
        );
        try testing.expectEqualSlices(
            u8,
            buf[(i * 2) * elem_size + elem_size .. (i * 2 + 2) * elem_size],
            &value,
        );
    }
}

test "feistel init produces correct r_mask" {
    var f: Feistel = .init(0, 2);
    try testing.expectEqual(1, f.r_mask);
    f = .init(0, 3);
    try testing.expectEqual(1, f.r_mask);
    f = .init(0, 4);
    try testing.expectEqual(1, f.r_mask);
    f = .init(0, 5);
    try testing.expectEqual(3, f.r_mask);
    f = .init(0, 1);
    try testing.expectEqual(0, f.r_mask);
    f = .init(0, math.maxInt(usize));
    try testing.expectEqual(math.maxInt(u32), f.r_mask);
}

test "feistel maps to correct output" {
    const n: usize = 10;
    var f: Feistel = .init(0, n);
    for (0..n) |i| {
        const r = f.value(i);
        try testing.expect(r < n);
    }
}

test "op permute get hit" {
    var w: Workload = .{ .key_count = 100, .operation = .get_hit, .requests = 20, .seed = 0 };

    var measure_and_warmup_equal = true;
    var measure_and_preload_equal = true;
    const perm: OpPermute = .init(w);

    for (0..w.requests) |i| {
        const p_idx = perm.preloadIdx(i);
        const w_idx = perm.warmupIdx(i);
        const m_idx = perm.measureIdx(i);

        try testing.expect(w_idx < w.key_count);
        try testing.expect(m_idx < w.key_count);

        if (m_idx != w_idx) measure_and_warmup_equal = false;
        if (m_idx != p_idx) measure_and_preload_equal = false;
    }

    try testing.expect(!measure_and_warmup_equal);
    try testing.expect(!measure_and_preload_equal);
}

test "op permute get miss" {
    const w: Workload = .{ .key_count = 20, .operation = .get_miss, .requests = 20, .seed = 0 };

    var all_equal = true;
    const perm: OpPermute = .init(w);

    for (0..w.requests) |i| {
        const p_idx = perm.warmupIdx(i);
        const m_idx = perm.measureIdx(i);

        try testing.expect(p_idx >= w.key_count);
        try testing.expect(m_idx >= w.key_count);

        if (m_idx != p_idx) all_equal = false;
    }

    try testing.expect(!all_equal);
}

test "op permute set insert" {
    const w: Workload = .{ .key_count = 100, .operation = .set_insert, .requests = 50, .seed = 0 };

    const perm: OpPermute = .init(w);
    for (0..w.requests) |i| {
        const p_idx = perm.warmupIdx(i);
        const m_idx = perm.measureIdx(i);

        try testing.expect(w.key_count - w.requests <= p_idx and p_idx < w.key_count);
        try testing.expect(w.key_count <= m_idx and m_idx < w.key_count + w.requests);
    }
}

test "op permute set replace" {
    var w: Workload = .{ .key_count = 100, .operation = .set_replace, .requests = 20, .seed = 0 };

    var all_equal = true;
    const perm: OpPermute = .init(w);
    for (0..w.requests) |i| {
        const p_idx = perm.warmupIdx(i);
        const m_idx = perm.measureIdx(i);

        try testing.expect(p_idx < w.key_count);
        try testing.expect(m_idx < w.key_count);

        if (m_idx != p_idx) all_equal = false;
    }

    try testing.expect(!all_equal);
}

test "op permute delete hit" {
    var w: Workload = .{ .key_count = 100, .operation = .delete_hit, .requests = 20, .seed = 2 };

    const perm: OpPermute = .init(w);

    try testing.expectEqual(w.key_count + w.requests, perm.preloadRange());

    for (0..w.requests) |i| {
        const p_idx = perm.warmupIdx(i);
        const m_idx = perm.measureIdx(i);

        try testing.expect(p_idx >= w.key_count);
        try testing.expect(m_idx < w.key_count);
    }
}
