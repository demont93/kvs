const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const enums = std.enums;
const heap = std.heap;
const Allocator = mem.Allocator;
const math = std.math;
const debug = std.debug;
const testing = std.testing;
const expectEqual = testing.expectEqual;
const expect = testing.expect;
const expectEqualSlices = testing.expectEqualSlices;
const Duration = std.Io.Duration;
const panic = debug.panic;
const assert = debug.assert;
const Random = std.Random;
const Io = std.Io;
const Clock = Io.Clock;

pub const max_key_size = 64 * 1024;
pub const max_value_size = 16 * 1024 * 1024;

pub const Op = enum(u8) {
    get = 0,
    set = 1,
    del = 2,

    pub fn is_read_only(self: Op) bool {
        return switch (self) {
            .get => true,
            .set, .del => false,
        };
    }
};

pub const request = struct {
    pub const frame_size = @sizeOf(u32) * 2 + 1;

    pub const InvalidFrame = enum {
        invalid_op,
        key_too_big,
        value_too_big,
        malformed,
    };

    pub fn validateFrame(
        frame: [frame_size]u8,
        err_reason: ?*InvalidFrame,
    ) bool {
        const op = parseFrameOp(frame, err_reason) catch {
            return false;
        };

        const kl = frameKeyLen(frame);
        const bl = frameBodyLen(frame);

        if (kl > bl) {
            if (err_reason) |r| r.* = .malformed;
            return false;
        }

        const vl = bl - kl;

        if (kl > max_key_size) {
            if (err_reason) |r| r.* = .key_too_big;
            return false;
        }

        if (vl > max_value_size) {
            if (err_reason) |r| r.* = .value_too_big;
            return false;
        }

        if (kl == 0) {
            if (err_reason) |r| r.* = .malformed;
            return false;
        }

        if (((op == Op.get or op == Op.del) and kl != bl)) {
            if (err_reason) |r| r.* = .malformed;
            return false;
        }

        return true;
    }

    pub inline fn frameBodyLen(frame: [frame_size]u8) usize {
        return @intCast(mem.readInt(u32, frame[0..@sizeOf(u32)], .big));
    }

    pub inline fn frameKeyLen(frame: [frame_size]u8) usize {
        return @intCast(mem.readInt(u32, frame[@sizeOf(u32) .. 2 * @sizeOf(u32)], .big));
    }

    pub inline fn frameValueLen(frame: [frame_size]u8) usize {
        return frameBodyLen(frame) - frameKeyLen(frame);
    }

    pub inline fn frameOp(frame: [frame_size]u8) Op {
        return @enumFromInt(frame[8]);
    }

    fn parseFrameOp(frame: [frame_size]u8, err_reason: ?*InvalidFrame) error{InvalidOp}!Op {
        if (std.enums.fromInt(Op, frame[8])) |op| {
            return op;
        } else {
            if (err_reason) |r| r.* = .invalid_op;
            return error.InvalidOp;
        }
    }

    // Assume correct op encoding and key and value length.
    pub fn encode(
        op: Op,
        frame: *[9]u8,
        key: []const u8,
        val: []const u8,
        bufs: *[3][]const u8,
    ) void {
        mem.writeInt(u32, frame[0..4], @intCast(key.len + val.len), .big);
        mem.writeInt(u32, frame[4..8], @intCast(key.len), .big);
        frame[8] = @intFromEnum(op);

        bufs[0] = frame;
        bufs[1] = key;
        bufs[2] = val;
    }

    pub fn encodeAlloc(
        op: Op,
        key: []const u8,
        val: []const u8,
        allocator: Allocator,
    ) ![]u8 {
        const len = 9 + key.len + val.len;
        const buf = try allocator.alloc(u8, len);
        errdefer allocator.free(buf);

        mem.writeInt(u32, buf[0..4], @intCast(key.len + val.len), .big);
        mem.writeInt(u32, buf[4..8], @intCast(key.len), .big);
        buf[8] = @intFromEnum(op);
        @memcpy(buf[9 .. 9 + key.len], key);
        @memcpy(buf[9 + key.len ..], val);
        return buf;
    }
};

pub const response = struct {
    pub const not_found = &[_]u8{ @intFromEnum(Code.NotFound), 0, 0, 0, 0 };
    pub const invalid = &[_]u8{ @intFromEnum(Code.Invalid), 0, 0, 0, 0 };
    pub const timeout = &[_]u8{ @intFromEnum(Code.Timeout), 0, 0, 0, 0 };
    pub const ok = &[_]u8{ @intFromEnum(Code.Ok), 0, 0, 0, 0 };
    pub const internal = &[_]u8{ @intFromEnum(Code.Internal), 0, 0, 0, 0 };

    pub const Code = enum(u8) {
        Ok = 0,
        NotFound = 1,
        Invalid = 2,
        Timeout = 3,
        Internal = 4,
    };

    pub fn encode(
        allocator: Allocator,
        code: Code,
        v: []const u8,
    ) error{OutOfMemory}![]u8 {
        std.debug.assert(switch (code) {
            .Ok => true,
            .NotFound, .Invalid, .Timeout, .Internal => v.len == 0,
        });

        if (v.len > max_value_size) {
            debug.panic("value {} is larger than max {}", .{ v.len, max_value_size });
        }

        const response_size = @sizeOf(u8) + @sizeOf(u32) + v.len;
        var msg = try allocator.alloc(u8, response_size);
        errdefer allocator.free(msg);

        msg[0] = @intFromEnum(code);

        const value_len: u32 = @intCast(v.len);
        mem.writeInt(u32, msg[1..5], value_len, .big);

        @memcpy(msg[5..], v);

        return msg;
    }

    pub fn value(allocator: Allocator, v: []const u8) error{OutOfMemory}![]u8 {
        return encode(allocator, .Ok, v);
    }

    pub const KeyError = error{ KeyTooLarge, EmptyKey };

    pub fn checkKey(key: []const u8) !void {
        if (key.len > max_key_size) {
            return error.KeyTooLarge;
        }
        if (key.len == 0) {
            return error.EmptyKey;
        }
    }

    pub const ValueError = error{ValueTooLarge};

    pub fn checkValue(val: []const u8) !void {
        if (val.len > max_value_size) {
            return error.ValueTooLarge;
        }
    }
};

pub fn exponentialBackoffWithJitter(
    io: Io,
    random: Random,
    attempt: i32,
    base: Duration,
    cap: Duration,
    deadline: Clock.Timestamp,
) error{ Canceled, Timeout }!void {
    const backoff = calculateExponentialBackoff(attempt, base, cap);
    const with_jitter = random.intRangeAtMost(
        i96,
        base.nanoseconds,
        backoff.nanoseconds,
    );
    const dur: Duration = .{ .nanoseconds = with_jitter };

    if (deadline.durationFromNow(io).raw.nanoseconds < dur.nanoseconds) {
        return error.Timeout;
    }

    try io.sleep(dur, .awake);
}

/// Asserts:
/// - base > 0
/// - attempt > 0
/// - cap > 0
inline fn calculateExponentialBackoff(attempt: i32, base: Duration, cap: Duration) Duration {
    assert(base.nanoseconds > 0);
    assert(attempt > 0);
    assert(cap.nanoseconds > 0);

    const capped_attempt: u7 = @intCast(@as(i32, @min((attempt - 1), 95)));
    const backoff: i96 = math.mul(i96, (@as(i96, 1) << capped_attempt), base.nanoseconds) catch
        math.maxInt(i96);
    return .{ .nanoseconds = @min(backoff, cap.nanoseconds) };
}

test "exponential backoff correct cap" {
    const Case = struct {
        cap: Duration,
        attempt: i32,
        base: Duration,
        expected: Duration,
    };

    const cases = [_]Case{
        .{
            .base = .fromMilliseconds(100),
            .attempt = 4,
            .cap = .fromMilliseconds(4000),
            .expected = .fromMilliseconds(800),
        },
        .{
            .base = .fromMilliseconds(200),
            .attempt = 4,
            .cap = .fromMilliseconds(500),
            .expected = .fromMilliseconds(500),
        },
        .{
            .base = .max,
            .attempt = 1,
            .cap = .fromMilliseconds(3),
            .expected = .fromMilliseconds(3),
        },
        .{
            .base = .max,
            .attempt = 5,
            .cap = .fromMilliseconds(3),
            .expected = .fromMilliseconds(3),
        },
        .{
            .base = .max,
            .attempt = math.maxInt(i32),
            .cap = .max,
            .expected = .max,
        },
        .{
            .base = .fromMilliseconds(1),
            .attempt = 4,
            .cap = .fromMilliseconds(4),
            .expected = .fromMilliseconds(4),
        },
    };

    for (&cases) |*c| {
        const result = calculateExponentialBackoff(
            c.attempt,
            c.base,
            c.cap,
        );
        try expectEqual(c.expected, result);
    }
}
