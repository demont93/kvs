const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const errno = linux.errno;

const load_gen = @import("load_gen.zig");

// pub fn run(cpu1: i32, cpu2: i32, port: u16) !void {}

fn openLoadGen() !i32 {
    var socks: [2]i32 = undefined;
    const sp_rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &socks);
    switch (errno(sp_rc)) {
        .SUCCESS => {},
        .OPNOTSUPP,
        .PROTONOSUPPORT,
        .AFNOSUPPORT,
        => |e| errnoBug("socketpair", e),
        else => |e| return errnoUnexpected("socketpair", e),
    }
    errdefer {
        linux.close(socks[0]);
        linux.close(socks[1]);
    }

    const mmap_rc = linux.mmap(
        null,
        1 << 20,
        .{ .WRITE = true, .READ = true },
        .{ .ANONYMOUS = true, .TYPE = .PRIVATE },
        -1,
        0,
    );
    const child_stack: [*]u8 = switch (errno(mmap_rc)) {
        .SUCCESS => @ptrFromInt(mmap_rc),
        .NOMEM => return error.OutOfMemory,
        .AGAIN,
        .BADF,
        .EXIST,
        .INVAL,
        .NODEV,
        .OVERFLOW,
        .ACCES,
        .PERM,
        .TXTBSY,
        => |e| errnoBug("mmap", e),
        else => |e| return errnoUnexpected("mmap", e),
    };

    defer switch (errno(linux.munmap(child_stack, 1 << 20))) {
        .SUCCESS => {},
        else => |e| errnoBug("munmap", e),
    };

    const clone_rc = linux.clone(
        &load_gen.loadGen,
        @intFromPtr(child_stack) + (1 << 20),
        linux.SIG.CHLD,
        0,
        null,
        0,
        null,
    );

    return switch (errno(clone_rc)) {
        .SUCCESS => @intCast(clone_rc),
        else => |e| return errnoUnexpected("clone", e),
    };
}

fn cpuNSet(n: i32) !linux.cpu_set_t {
    var set = std.mem.zeroes(linux.cpu_set_t);
    return try setCpuset(&set, n);
}

fn setCpuset(set: *linux.cpu_set_t, n: i32) !void {
    const Elem = @typeInfo(linux.cpu_set_t).array.child;

    const nu = std.math.cast(u32, n) orelse return error.InvalidCpu;

    const index = nu / @bitSizeOf(Elem);
    if (index >= (@sizeOf(linux.cpu_set_t) / @sizeOf(Elem))) {
        return error.CpuOutOfBounds;
    }

    const pos: @Int(.unsigned, std.math.log2(@bitSizeOf(Elem))) = @intCast(nu % @bitSizeOf(Elem));
    const one: Elem = 1;
    const mask = one << pos;
    set[index] |= mask;
}

fn errnoBug(call: []const u8, e: linux.E) noreturn {
    std.debug.panic("errno bug when calling {}: {t}", .{ call, e });
}

fn errnoUnexpected(call: []const u8, e: linux.E) error{Unexpected} {
    std.debug.print("unexpected errno when calling {}: {t}", .{ call, e });
}

test "setCpuset" {
    var set = std.mem.zeroes(linux.cpu_set_t);
    try setCpuset(&set, 7);
    try testing.expectEqual(1, linux.CPU_COUNT(set));
    try testing.expectEqual(128, set[0]);
    set = std.mem.zeroes(linux.cpu_set_t);
    try testing.expectError(error.CpuOutOfBounds, setCpuset(&set, std.math.maxInt(i32)));
}
