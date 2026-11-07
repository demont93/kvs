const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const errno = linux.errno;

const load_gen = @import("load_gen.zig");

const LoadGenHandle = struct {
    pid: i32,
    sock: i32,

    /// Messages the Load Generator to start the measure phase. Should be sent after attaching
    /// profiler and other tooling and receiving ready from the load generator, indicating all
    /// setup was performed.
    fn start(self: *LoadGenHandle) !void {
        const msg = @intFromEnum(load_gen.Message.start);
        const write_rc = linux.write(self.fd, @ptrCast(&msg), 1);
        while (true) {
            const n: i32 = switch (errno()) {
                .SUCCESS => @intCast(write_rc),
                .INTR => continue,
                .INVAL,
                .BADF,
                => |e| errnoBug("write", e),
                .CONNRESET, .PIPE => return error.ConnectionReset,
                else => |e| return errnoUnexpected("write", e),
            };
            if (n == 1) break;
        }
    }

    fn waitClose(self: *LoadGenHandle) !u8 {
        const close_result = switch (errno(linux.close(self.sock))) {
            .SUCCESS => {},
            else => |e| errnoUnexpected("close", e),
        };
        self.sock = -1;
        const code = waitChild(self.pid);
        self.pid = std.math.minInt(i32);

        if (close_result) |_| {
            return code;
        } else |e| {
            return e;
        }
    }

    fn kill(self: *LoadGenHandle) void {
        killChild(self.pid);
        self.pid = std.math.minInt(i32);
        switch (errno(linux.close(self.sock))) {
            .SUCCESS => {},
            else => |e| _ = errnoUnexpected("close", e),
        }
        self.sock = -1;
    }
};

pub fn run(cmd: anytype) !void {
    const load_gen_handle = try openLoadGen(cmd);
    _ = load_gen_handle;
    @panic("unimplemented");
}

fn openLoadGen(cmd: anytype) error{Unexpected}!LoadGenHandle {
    var socks: [2]i32 = undefined;
    try switch (errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &socks))) {
        .SUCCESS => {},
        .OPNOTSUPP,
        .PROTONOSUPPORT,
        .AFNOSUPPORT,
        => |e| errnoBug("socketpair", e),
        else => |e| errnoUnexpected("socketpair", e),
    };

    const pid_result = openLoadGenMakeStack(cmd);

    const close_result = switch (errno(linux.close(socks[0]))) {
        .SUCCESS => {},
        else => |e| errnoUnexpected("close", e),
    };

    if (pid_result) |pid| {
        if (close_result) |_| {
            return LoadGenHandle{ .sock = socks[1], .pid = pid };
        } else |_| {}
        killChild(pid);
    } else |_| {}

    _ = linux.close(socks[1]);
    try pid_result;
    try close_result;
}

fn openLoadGenMakeStack(cmd: anytype) error{Unexpected}!i32 {
    const mmap_rc = linux.mmap(
        null,
        1 << 20,
        .{ .WRITE = true, .READ = true },
        .{ .ANONYMOUS = true, .TYPE = .PRIVATE },
        -1,
        0,
    );
    const child_stack = try switch (errno(mmap_rc)) {
        .SUCCESS => @as([*]u8, @ptrFromInt(mmap_rc)),
        .NOMEM => error.OutOfMemory,
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
        else => |e| errnoUnexpected("mmap", e),
    };

    const result = openLoadGenMakeStackClone(cmd, child_stack);

    switch (errno(linux.munmap(child_stack, 1 << 20))) {
        .SUCCESS => {},
        else => |e| errnoBug("munmap", e),
    }

    return result;
}

fn openLoadGenMakeStackClone(cmd: anytype, stack: [*]u8) error{Unexpected}!i32 {
    const load_gen_ctx: load_gen.Context = .{
        .cpu = cmd.cpu2,
        .workload = .{
            .key_count = cmd.@"key-count",
            .operation = cmd.op,
            .requests = cmd.requests,
            .seed = cmd.seed,
        },
    };
    const clone_rc = linux.clone(
        &load_gen.loadGen,
        @intFromPtr(stack) + (1 << 20),
        linux.SIG.CHLD,
        @intFromPtr(&load_gen_ctx),
        null,
        0,
        null,
    );

    return switch (errno(clone_rc)) {
        .SUCCESS => @intCast(clone_rc),
        else => |e| errnoUnexpected("clone", e),
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

fn waitChild(pid: i32) u8 {
    var status: u32 = undefined;
    switch (errno(linux.waitpid(pid, &status, 0))) {
        .SUCCESS => {},
        else => |e| errnoBug("waitpid", e),
    }
    if (linux.W.IFEXITED(status)) {
        return linux.W.EXITSTATUS(status);
    } else {
        var exit_str: []const u8 = undefined;
        var cause: []const u8 = undefined;
        if (linux.W.IFSIGNALED(status)) {
            exit_str = "signaled";
            cause = @tagName(linux.W.TERMSIG(status));
        } else if (linux.W.IFSTOPPED(status)) {
            exit_str = "stopped";
            cause = @tagName(@as(linux.SIG, @enumFromInt(linux.W.STOPSIG(status))));
        } else {
            exit_str = "unknown";
            cause = "unknown";
        }
        std.debug.panic("child {s} with {s}\n", .{ exit_str, cause });
    }
}

fn killChild(pid: i32) void {
    switch (errno(linux.kill(pid, linux.SIG.KILL))) {
        .SUCCESS, .SRCH => {},
        else => |e| errnoBug("kill", e),
    }
    var status: u32 = undefined;
    switch (errno(linux.waitpid(pid, &status, 0))) {
        .SUCCESS => {},
        else => |e| errnoBug("waitpid", e),
    }
}

fn errnoBug(call: []const u8, e: linux.E) noreturn {
    std.debug.panic("errno bug when calling {}: {t}\n", .{ call, e });
}

fn errnoUnexpected(call: []const u8, e: linux.E) error{Unexpected} {
    std.debug.print("unexpected errno when calling {}: {t}\n", .{ call, e });
}

test "setCpuset" {
    var set = std.mem.zeroes(linux.cpu_set_t);
    try setCpuset(&set, 7);
    try testing.expectEqual(1, linux.CPU_COUNT(set));
    try testing.expectEqual(128, set[0]);
    set = std.mem.zeroes(linux.cpu_set_t);
    try testing.expectError(error.CpuOutOfBounds, setCpuset(&set, std.math.maxInt(i32)));
}
