const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const errno = linux.errno;

const load_gen = @import("load_gen.zig");
const srv = @import("srv.zig");

const ServerHandle = struct {
    pid: i32,
    sock: i32,

    fn wait(self: *ServerHandle) !u8 {
        return waitHandle(&self.pid, &self.sock);
    }

    fn kill(self: *ServerHandle) void {
        return killHandle(&self.pid, &self.sock);
    }
};

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

    fn wait(self: *LoadGenHandle) !u8 {
        return waitHandle(&self.pid, &self.sock);
    }

    fn kill(self: *LoadGenHandle) void {
        return killHandle(&self.pid, &self.sock);
    }
};

pub fn run(cmd: anytype) !void {
    const lg_ctx: load_gen.Context = .{
        .cpu = cmd.cpu2,
        .workload = .{
            .key_count = cmd.@"key-count",
            .operation = cmd.op,
            .requests = cmd.requests,
            .seed = cmd.seed,
        },
    };

    const lg_handle = try openLoadGen(lg_ctx);

    const server_ctx: srv.Context = .{
        .cpu = cmd.cpu1,
    };

    const server_handle = openServer(server_ctx) catch |e| {
        lg_handle.kill();
        return e;
    };

    _ = server_handle;
    @panic("unimplemented");
}

fn openServer(ctx: srv.Context) error{Unexpected}!ServerHandle {
    const socks = try socketPair();

    const pid = clone(&ctx, srv.processMain) catch |e| {
        closeFdLog(socks[0]);
        closeFdLog(socks[1]);
        return e;
    };

    closeFd(socks[0]) catch |e| {
        closeFdLog(socks[0]);
        killChild(pid);
        return e;
    };

    return ServerHandle{ .pid = pid, .sock = socks[1] };
}

fn openLoadGen(ctx: load_gen.Context) error{Unexpected}!LoadGenHandle {
    const socks = try socketPair();

    const pid = clone(ctx, &load_gen.processMain) catch |e| {
        closeFdLog(socks[0]);
        closeFdLog(socks[1]);
        return e;
    };

    closeFd(socks[0]) catch |e| {
        closeFdLog(socks[1]);
        killChild(pid);
        return e;
    };

    return LoadGenHandle{ .sock = socks[1], .pid = pid };
}

fn clone(arg: *anyopaque, f: *const fn (*anyopaque) callconv(.c) u8) !i32 {
    const stack = try makeStack();
    defer destroyStack(stack);

    const clone_rc = linux.clone(
        f,
        @intFromPtr(stack) + stack.len,
        linux.SIG.CHLD,
        @intFromPtr(arg),
        null,
        0,
        null,
    );

    return switch (errno(clone_rc)) {
        .SUCCESS => @intCast(clone_rc),
        else => |e| errnoUnexpected("clone", e),
    };
}

fn makeStack() ![]u8 {
    const mmap_rc = linux.mmap(
        null,
        1 << 20,
        .{ .WRITE = true, .READ = true },
        .{ .ANONYMOUS = true, .TYPE = .PRIVATE },
        -1,
        0,
    );

    return switch (errno(mmap_rc)) {
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
}

fn destroyStack(stack: []u8) void {
    switch (errno(linux.munmap(stack, 1 << 20))) {
        .SUCCESS => {},
        else => |e| errnoBug("munmap", e),
    }
}

fn closeFd(fd: i32) !void {
    return switch (errno(linux.close(fd))) {
        .SUCCESS => {},
        else => |e| errnoUnexpected("close", e),
    };
}

fn closeFdLog(fd: i32) void {
    closeFd(fd) catch {};
}

fn socketPair() error{Unexpected}![2]i32 {
    var socks: [2]i32 = undefined;

    try switch (errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &socks))) {
        .SUCCESS => {},
        .OPNOTSUPP,
        .PROTONOSUPPORT,
        .AFNOSUPPORT,
        => |e| errnoBug("socketpair", e),
        else => |e| errnoUnexpected("socketpair", e),
    };

    return socks;
}

fn waitHandle(pid: *i32, sock_fd: *i32) !u8 {
    const close_result = closeFd(sock_fd.*);
    sock_fd.* = -1;
    const code = waitChild(pid.*);
    pid.* = std.math.minInt(i32);

    if (close_result) |_| {
        return code;
    } else |e| {
        return e;
    }
}

fn killHandle(pid: *i32, sock_fd: *i32) void {
    killChild(pid.*);
    pid.* = std.math.minInt(i32);
    closeFdLog(sock_fd.*);
    sock_fd.* = -1;
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
