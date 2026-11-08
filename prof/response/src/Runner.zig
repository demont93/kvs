const std = @import("std");
const linux = std.os.linux;
const testing = std.testing;
const errno = linux.errno;
const panic = std.debug.panic;
const ArenaAllocator = std.heap.ArenaAllocator;
const process = std.process;
const Io = std.Io;
const mem = std.mem;

const load_gen = @import("load_gen.zig");
const srv = @import("srv.zig");

const Runner = struct {
    server_handle: ServerHandle,
    lg_handle: LoadGenHandle,

    fn init(
        self: *Runner,
        server_ctx: srv.Context,
        lg_ctx: load_gen.Context,
    ) error{Unexpected}!void {
        self.lg_handle = try openLoadGen(lg_ctx);

        self.server_handle = openServer(server_ctx) catch |e| {
            self.lg_handle.kill();
            return e;
        };
    }

    fn profile(self: *Runner, io: Io) !void {
        try self.lg_handle.awaitReady();

        const perf = Perf.record(io, self.server_handle.pid);

        try perf.enable();
        try self.lg_handle.start();
        

        // try self.lg_handle.awaitDone();
    }

    fn attachProfilingTools(self: Runner) !void {
        _ = self;
        @panic("unimplemented");
    }
};

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

    fn awaitReady(self: *LoadGenHandle) !void {
        var buf: [1]u8 = undefined;

        while (true) {
            const read_rc = linux.read(self.sock, &buf, 1);
            switch (errno(read_rc)) {
                .SUCCESS => if (read_rc == 0) return error.LGClosed else break,
                .INTR => continue,
                .PIPE, .CONNRESET => return error.LGClosed,
                .AGAIN,
                .BADF,
                .FAULT,
                .INVAL,
                .ISDIR,
                .NOTSOCK,
                => |e| errnoBug("read", e),
                else => |e| return errnoUnexpected("read", e),
            }
        }

        const msg = std.enums.fromInt(load_gen.Message, buf[0]) orelse
            panic("invalid message from load generator: {}\n", .{buf[0]});

        switch (msg) {
            .err => return error.LGError,
            .ready => return,
            .done, .start => return panic("invalid message from load generator: {t}", .{msg}),
        }
    }

    /// Messages the Load Generator to start the measure phase. Should be sent after attaching
    /// profiler and other tooling and receiving ready from the load generator, indicating all
    /// setup was performed.
    fn start(self: *LoadGenHandle) !void {
        const msg = @intFromEnum(load_gen.Message.start);

        while (true) {
            const write_rc = linux.write(self.fd, @ptrCast(&msg), 1);

            const n: i32 = switch (errno(write_rc)) {
                .SUCCESS => @intCast(write_rc),
                .INTR => continue,
                .INVAL,
                .AGAIN,
                .BADF,
                .NOTSOCK,
                => |e| errnoBug("write", e),
                .CONNRESET, .PIPE => return error.ServerClosed,
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

const Perf = struct {
    const ack = "ack\n";

    child_proc: process.Child,
    ack_pipe: i32,
    ctl_pipe: i32,

    const PipePairs = struct {
        my_r: i32,
        my_w: i32,
        their_r: i32,
        their_w: i32,

        fn init() error{Unexpected}!PipePairs {
            const pipes1 = try makePipe();
            errdefer {
                closeFdLog(pipes1[0]);
                closeFdLog(pipes1[1]);
            }
            const pipes2 = try makePipe();

            return .{
                .my_r = pipes1[0],
                .my_w = pipes1[1],
                .their_r = pipes2[0],
                .their_w = pipes2[1],
            };
        }

        fn noCloExecTheirs(self: PipePairs) !void {
            try noCloexec(self.their_r);
            try noCloexec(self.their_w);
        }

        fn closeLogMine(self: *PipePairs) void {
            closeFdLog(self.my_r);
            closeFdLog(self.my_w);
        }

        fn closeTheirs(self: *PipePairs) !void {
            const r1 = closeFd(self.their_r);
            const r2 = closeFd(self.their_w);

            try r1;
            try r2;
        }
    };

    fn wait(self: *Perf, io: Io) !void {
        const e1 = closeFd(self.ack_pipe);
        const e2 = closeFd(self.ctl_pipe);
        _ = try self.child_proc.wait(io);
        try e1;
        try e2;
    }

    fn kill(self: *Perf, io: Io) !void {
        closeFdLog(self.ack_pipe);
        closeFdLog(self.ctl_pipe);
        self.child_proc.kill(io);
    }

    fn enable(self: *Perf) !void {
        try self.send_msg("enable");
    }

    fn stop(self: *Perf) !void {
        try self.send_msg("stop");
    }

    fn send_msg(self: *Perf, msg: []const u8) !void {
        var written = 0;
        while (written < msg.len) {
            const write_rc = linux.write(self.ctl_pipe, msg[written..], msg.len - written);
            const n = try switch (errno(write_rc)) {
                .SUCCESS => @as(i32, @intCast(write_rc)),
                .INTR => continue,
                .BADF, .FAULT, .INVAL, .FBIG => |e| errnoBug("write", e),
                else => |e| errnoUnexpected("write", e),
            };
            written += n;
        }

        var read = 0;
        var buf: [ack.len]u8 = undefined;
        while (read < ack.len) {
            const read_rc = linux.read(self.ack_pipe, buf[read..], ack.len - read);
            const n = try switch (errno(read_rc)) {
                .SUCCESS => if (read_rc == 0) error.UnexpectedEof else @as(i32, @intCast(read_rc)),
                .INTR => continue,
                .BADF, .FAULT, .INVAL => |e| errnoBug("read", e),
                else => |e| errnoUnexpected("read", e),
            };
            read += n;
        }
    }

    fn record(io: Io, arena: *ArenaAllocator, pid: i32) !Perf {
        const pipe_pairs: PipePairs = try .init();
        errdefer pipe_pairs.closeLogMine();

        const child: process.Child = blk: {
            errdefer pipe_pairs.closeTheirs() catch {};

            const argv = [_][]const u8{
                "perf",
                "record",
                "-g",
                "-e",
                "cycles",
                "-p",
                try pidStr(arena, pid),
                "--delay=-1",
                try controlFdArg(arena, pipe_pairs[2], pipe_pairs[1]),
            };

            try pipe_pairs.noCloExecTheirs();
            break :blk try process.spawn(io, .{ .argv = argv });
        };

        try pipe_pairs.closeTheirs();

        return .{ .child_proc = child, .ack_pipe = pipe_pairs.my_r, .ctl_pipe = pipe_pairs.my_w };
    }

    fn controlFdArg(
        arena: *ArenaAllocator,
        they_read: i32,
        they_write: i32,
    ) error{OutOfMemory}![]u8 {
        return std.fmt.allocPrint(
            arena.allocator(),
            "--control=fd:{},{}",
            .{ they_read, they_write },
        );
    }

    fn pidStr(arena: *ArenaAllocator, pid: i32) error{OutOfMemory}![]u8 {
        return std.fmt.allocPrint(arena.allocator(), "{}", .{pid});
    }

    /// Makes a pipe with CLOEXEC.
    fn makePipe() error{Unexpected}![2]i32 {
        var fds = [2]i32{ -1, -1 };

        const pipe_rc = linux.pipe2(&fds, .{ .CLOEXEC = true });
        try switch (errno(pipe_rc)) {
            .SUCCESS => {},
            .FAULT, .INVAL => errnoBug(),
            else => |e| return errnoUnexpected("pipe", e),
        };

        return fds;
    }

    fn noCloexec(fd: i32) error{Unexpected}!void {
        var flags = try getFdFlags(fd);
        flags &= ~linux.FD_CLOEXEC;
        return switch (errno(linux.fcntl(fd, linux.F.SETFD, flags))) {
            .SUCCESS => {},
            .BADF, .FAULT, .INVAL => |e| errnoBug("fcntl", e),
            else => |e| errnoUnexpected("fcntl", e),
        };
    }

    fn getFdFlags(fd: i32) error{Unexpected}!i32 {
        const f_rc = linux.fcntl(fd, linux.F.GETFD, 0);
        return switch (errno(f_rc)) {
            .SUCCESS => @as(i32, @intCast(f_rc)),
            .BADF, .FAULT, .INVAL => |e| errnoBug("fcntl", e),
            else => |e| errnoUnexpected("fcntl", e),
        };
    }
};

pub fn run(cmd: anytype) !void {
    const server_ctx: srv.Context = .{
        .cpu = cmd.cpu1,
    };

    const lg_ctx: load_gen.Context = .{
        .cpu = cmd.cpu2,
        .workload = .{
            .key_count = cmd.@"key-count",
            .operation = cmd.op,
            .requests = cmd.requests,
            .seed = cmd.seed,
        },
    };

    var runner: Runner = undefined;
    try runner.init(server_ctx, lg_ctx);
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
