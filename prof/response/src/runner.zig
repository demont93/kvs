const std = @import("std");
const linux = std.os.linux;
const errno = linux.errno;
const panic = std.debug.panic;
const ArenaAllocator = std.heap.ArenaAllocator;
const process = std.process;
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;

const load_gen = @import("load_gen.zig");
const srv = @import("srv.zig");

const Err = error{Err};

const Runner = struct {
    // fd numbers
    const fd_lgen = 0;
    const fd_serv = 1;
    const fd_perf = 2;

    server_handle: ServerHandle,
    lg_handle: LoadGenHandle,

    fn init(
        self: *Runner,
        server_ctx: *srv.Context,
        lg_ctx: *load_gen.Context,
    ) Err!void {
        errdefer logErr("initializing runner\n", .{}) catch {};

        self.lg_handle = try openLoadGen(lg_ctx);

        self.server_handle = openServer(server_ctx) catch |e| {
            self.lg_handle.kill();
            return e;
        };
    }

    fn wait(self: *Runner) Err!void {
        errdefer logErr("waiting for runner children\n", .{}) catch {};

        const lgen_result = self.lg_handle.wait();
        const serv_result = self.server_handle.close();

        try lgen_result;
        try serv_result;
    }

    fn kill(self: *Runner) void {
        logErr("killing runner children\n", .{}) catch {};
        self.lg_handle.kill();
        self.server_handle.close() catch {};
    }

    fn profile(self: *Runner, io: Io, arena: *ArenaAllocator) !void {
        errdefer logErr("running profile on runner\n", .{}) catch {};

        var report: srv.Report = undefined;
        var perf = try Perf.record(io, arena, self.server_handle.pid);

        {
            errdefer perf.kill(io);

            var poll_fds: [3]linux.pollfd = undefined;
            self.initPollFds(perf, &poll_fds);

            try self.lg_handle.awaitReady();

            try perf.enable();
            try self.lg_handle.start();

            _ = try poll(&poll_fds);

            try perf.stop();
            try self.server_handle.end();
            try self.lg_handle.awaitDone();

            try self.server_handle.awaitResult(&report);
        }

        try perf.wait(io);
    }

    fn initPollFds(self: Runner, perf: Perf, poll_fds: *[3]linux.pollfd) void {
        poll_fds[fd_lgen].fd = self.lg_handle.sock;
        poll_fds[fd_serv].fd = self.server_handle.sock;
        poll_fds[fd_perf].fd = perf.ack_pipe;
        for (poll_fds) |*pfd| {
            pfd.events = linux.POLL.IN;
        }
    }

    fn poll(poll_fds: []linux.pollfd) Err!i32 {
        while (true) {
            const poll_rc = linux.poll(poll_fds.ptr, poll_fds.len, -1);

            return switch (errno(poll_rc)) {
                .SUCCESS => @as(i32, @intCast(poll_rc)),
                .INTR => continue,
                .FAULT, .INVAL => |e| errnoBug("poll", e),
                else => |e| errnoUnexpected("poll", e),
            };
        }
    }
};

const ServerHandle = struct {
    pid: i32,
    sock: i32,
    status: enum { running, done, unknown } = .running,

    fn close(self: *ServerHandle) Err!void {
        errdefer logErr("closing server\n", .{}) catch {};

        return switch (self.status) {
            .running => self.endWait(),
            .done => self.wait(),
            .unknown => self.kill(),
        };
    }

    fn awaitResult(self: *ServerHandle, report: *srv.Report) Err!void {
        errdefer logErr("awaiting server result\n", .{}) catch {};

        recvAll(self.sock, @ptrCast(report)) catch |err| {
            switch (err) {
                error.UnexpectedEof => self.status = .done,
                error.Err => self.status = .unknown,
            }
            return error.Err;
        };
    }

    fn endWait(self: *ServerHandle) Err!void {
        self.end() catch {
            self.kill();
            return;
        };
        try self.wait();
    }

    fn end(self: *ServerHandle) Err!void {
        self.status = .done;
        const msg = @intFromEnum(srv.Messages.end);
        try sendAll(self.sock, @as(*const [1]u8, &msg));
    }

    fn wait(self: *ServerHandle) Err!void {
        errdefer logErr("waiting for server pid\n", .{}) catch {};

        const code = try waitHandle(&self.pid, &self.sock);

        switch (@as(srv.ExitCode, @enumFromInt(code))) {
            .success => {},
        }
    }

    fn kill(self: *ServerHandle) void {
        std.debug.print("server process killed\n", .{});
        return killHandle(&self.pid, &self.sock);
    }
};

const LoadGenHandle = struct {
    pid: i32,
    sock: i32,

    fn awaitDone(self: *LoadGenHandle) Err!void {
        errdefer logErr("awaiting done message from load generator\n", .{});
        return switch (try self.recvCode()) {
            .err => logErr("received err message\n", .{}),
            .done => {},
            else => |m| invalidMessageReceived(m),
        };
    }

    fn awaitReady(self: *LoadGenHandle) Err!void {
        errdefer logErr("awaiting ready message from load generator\n", .{});
        return switch (try self.recvCode()) {
            .err => logErr("received err message\n", .{}),
            .ready => {},
            else => |m| invalidMessageReceived(m),
        };
    }

    /// Messages the Load Generator to start the measure phase. Should be sent after attaching
    /// profiler and other tooling and receiving ready from the load generator, indicating all
    /// setup was performed.
    fn start(self: *LoadGenHandle) Err!void {
        errdefer logErr("starting load generator\n", .{}) catch {};

        const msg = @intFromEnum(load_gen.Message.start);
        try sendAll(self.sock, @as(*const [1]u8, &msg));
    }

    fn recvCode(self: *LoadGenHandle) Err!load_gen.Message {
        var buf: [1]u8 = undefined;

        recvAll(self.sock, &buf) catch return Err.Err;

        const msg = std.enums.fromInt(load_gen.Message, buf[0]) orelse
            panic("invalid message from load generator: {}\n", .{buf[0]});

        return switch (msg) {
            .err, .ready, .done => |e| e,
            .start => |m| invalidMessageReceived(m),
        };
    }

    fn invalidMessageReceived(msg: load_gen.Message) noreturn {
        panic("invalid message from load generator: {t}", .{msg});
    }

    fn wait(self: *LoadGenHandle) Err!void {
        errdefer logErr("waiting for load generator pid\n", .{}) catch {};

        const code = waitHandle(&self.pid, &self.sock) catch return Err.Err;
        switch (@as(load_gen.ExitCode, @enumFromInt(code))) {
            .success => {},
        }
    }

    fn kill(self: *LoadGenHandle) void {
        std.debug.print("load generator process killed\n", .{});
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

        fn init() Err!PipePairs {
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

        fn noCloExecTheirs(self: PipePairs) Err!void {
            try noCloexec(self.their_r);
            try noCloexec(self.their_w);
        }

        fn closeLogMine(self: *PipePairs) void {
            closeFdLog(self.my_r);
            closeFdLog(self.my_w);
        }

        fn closeTheirs(self: *PipePairs) Err!void {
            const r1 = closeFd(self.their_r);
            const r2 = closeFd(self.their_w);

            try r1;
            try r2;
        }
    };

    fn wait(self: *Perf, io: Io) Err!void {
        errdefer logErr("waiting for perf pid\n", .{}) catch {};

        closeFdLog(self.ack_pipe);
        const write_pipe_close_result = closeFd(self.ctl_pipe);

        // There is a gap on the current standard where if io gets canceled, it leaks the
        // process. Store the pid and signal it on error to avoid leaks.
        const child_pid = self.child_proc.id.?;

        _ = self.child_proc.wait(io) catch |err| {
            std.debug.print("perf wait error: {t}\n", .{err});

            // kill with stored pid.
            switch (errno(linux.kill(child_pid, linux.SIG.KILL))) {
                .SUCCESS => {},
                else => |e| errnoBug("kill", e),
            }

            // wait with stored pid.
            var status: u32 = 0;
            while (true) {
                switch (errno(linux.waitpid(child_pid, &status, 0))) {
                    .SUCCESS => break,
                    .INTR => continue,
                    else => |e| errnoBug("waitpid", e),
                }
            }

            return error.Err;
        };

        try write_pipe_close_result;
    }

    fn kill(self: *Perf, io: Io) void {
        closeFdLog(self.ack_pipe);
        closeFdLog(self.ctl_pipe);
        self.child_proc.kill(io);
    }

    fn enable(self: *Perf) !void {
        errdefer logErr("enabling perf\n", .{}) catch {};
        try self.send_msg("enable");
    }

    fn stop(self: *Perf) !void {
        errdefer logErr("stopping perf\n", .{}) catch {};
        try self.send_msg("stop");
    }

    fn send_msg(self: *Perf, msg: []const u8) Err!void {
        errdefer logErr("sending msg to perf\n", .{}) catch {};

        var n_written: usize = 0;
        while (n_written < msg.len) {
            const write_rc = linux.write(self.ctl_pipe, msg[n_written..].ptr, msg.len - n_written);
            const n = try switch (errno(write_rc)) {
                .SUCCESS => write_rc,
                .INTR => continue,
                .BADF, .FAULT, .INVAL, .FBIG => |e| errnoBug("write", e),
                else => |e| errnoUnexpected("write", e),
            };
            n_written += n;
        }

        var n_read: usize = 0;
        var buf: [ack.len]u8 = undefined;
        while (n_read < ack.len) {
            const read_rc = linux.read(self.ack_pipe, buf[n_read..].ptr, ack.len - n_read);
            const n = try switch (errno(read_rc)) {
                .SUCCESS => if (read_rc == 0)
                    logErr("unexpected eof\n", .{})
                else
                    read_rc,
                .INTR => continue,
                .BADF, .FAULT, .INVAL => |e| errnoBug("read", e),
                else => |e| errnoUnexpected("read", e),
            };
            n_read += n;
        }
    }

    fn record(io: Io, arena: *ArenaAllocator, pid: i32) Err!Perf {
        errdefer logErr("recording with perf\n", .{}) catch {};

        var pipe_pairs: PipePairs = try .init();
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
                try controlFdArg(arena, pipe_pairs.their_r, pipe_pairs.their_w),
            };

            try pipe_pairs.noCloExecTheirs();
            break :blk process.spawn(io, .{ .argv = &argv }) catch |err| switch (err) {
                else => |e| return logErr("failed to spawn perf: {t}\n", .{e}),
            };
        };

        try pipe_pairs.closeTheirs();

        return .{ .child_proc = child, .ack_pipe = pipe_pairs.my_r, .ctl_pipe = pipe_pairs.my_w };
    }

    fn controlFdArg(
        arena: *ArenaAllocator,
        they_read: i32,
        they_write: i32,
    ) Err![]u8 {
        return std.fmt.allocPrint(
            arena.allocator(),
            "--control=fd:{},{}",
            .{ they_read, they_write },
        ) catch logErr("out of memory\n", .{});
    }

    fn pidStr(arena: *ArenaAllocator, pid: i32) Err![]u8 {
        return std.fmt.allocPrint(arena.allocator(), "{}", .{pid}) catch
            logErr("out of memory\n", .{});
    }

    /// Makes a pipe with CLOEXEC.
    fn makePipe() Err![2]i32 {
        var fds = [2]i32{ -1, -1 };

        const pipe_rc = linux.pipe2(&fds, .{ .CLOEXEC = true });
        try switch (errno(pipe_rc)) {
            .SUCCESS => {},
            .FAULT, .INVAL => |e| errnoBug("pipe2", e),
            else => |e| errnoUnexpected("pipe", e),
        };

        return fds;
    }

    fn noCloexec(fd: i32) Err!void {
        var flags: usize = @intCast(try getFdFlags(fd));
        flags &= ~@as(usize, linux.FD_CLOEXEC);
        return switch (errno(linux.fcntl(fd, linux.F.SETFD, flags))) {
            .SUCCESS => {},
            .BADF, .FAULT, .INVAL => |e| errnoBug("fcntl", e),
            else => |e| errnoUnexpected("fcntl", e),
        };
    }

    fn getFdFlags(fd: i32) Err!i32 {
        const f_rc = linux.fcntl(fd, linux.F.GETFD, 0);
        return switch (errno(f_rc)) {
            .SUCCESS => @as(i32, @intCast(f_rc)),
            .BADF, .FAULT, .INVAL => |e| errnoBug("fcntl", e),
            else => |e| errnoUnexpected("fcntl", e),
        };
    }
};

pub fn run(io: Io, arena: *ArenaAllocator, cmd: anytype) Err!void {
    var server_ctx: srv.Context = .{
        .cpu = try cpuNSet(cmd.cpu1),
    };

    var lg_ctx: load_gen.Context = .{
        .cpu = try cpuNSet(cmd.cpu2),
        .workload = .{
            .key_count = cmd.@"key-count",
            .operation = cmd.op,
            .requests = cmd.requests,
            .seed = cmd.seed,
        },
    };

    var runner: Runner = undefined;
    try runner.init(&server_ctx, &lg_ctx);

    {
        errdefer runner.kill();
        try runner.profile(io, arena);
    }

    try runner.wait();
}

fn openServer(ctx: *srv.Context) Err!ServerHandle {
    errdefer logErr("opening server\n", .{}) catch {};

    const socks = try socketPair();

    const pid = clone(ctx, &srv.processMain) catch |e| {
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

fn openLoadGen(ctx: *load_gen.Context) Err!LoadGenHandle {
    errdefer logErr("opening load generator\n", .{}) catch {};

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

fn clone(arg: ?*anyopaque, f: *const fn (usize) callconv(.c) u8) Err!i32 {
    errdefer logErr("clone\n", .{}) catch {};

    const stack = try makeStack();
    defer destroyStack(stack);

    const clone_rc = linux.clone(
        f,
        @intFromPtr(stack.ptr) + stack.len,
        @intFromEnum(linux.SIG.CHLD),
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

fn makeStack() Err![]u8 {
    const mmap_rc = linux.mmap(
        null,
        1 << 20,
        .{ .WRITE = true, .READ = true },
        .{ .ANONYMOUS = true, .TYPE = .PRIVATE },
        -1,
        0,
    );

    return switch (errno(mmap_rc)) {
        .SUCCESS => @as([*]u8, @ptrFromInt(mmap_rc))[0 .. 1 << 20],
        .NOMEM => logErr("mmap: out of memory\n", .{}),
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
    switch (errno(linux.munmap(stack.ptr, stack.len))) {
        .SUCCESS => {},
        else => |e| errnoBug("munmap", e),
    }
}

fn closeFd(fd: i32) Err!void {
    return switch (errno(linux.close(fd))) {
        .SUCCESS => {},
        .INTR, .IO => |e| logErr("close failed: {t}\n", .{e}),
        .BADF => |e| errnoBug("close", e),
        else => |e| errnoUnexpected("close", e),
    };
}

fn closeFdLog(fd: i32) void {
    closeFd(fd) catch {};
}

fn socketPair() Err![2]i32 {
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

fn waitHandle(pid: *i32, sock_fd: *i32) Err!u8 {
    const close_result = closeFd(sock_fd.*);
    sock_fd.* = -1;
    const code = waitChild(pid.*);
    pid.* = std.math.minInt(i32);

    _ = try code;
    _ = try close_result;

    return code;
}

fn killHandle(pid: *i32, sock_fd: *i32) void {
    killChild(pid.*);
    pid.* = std.math.minInt(i32);
    closeFdLog(sock_fd.*);
    sock_fd.* = -1;
}

fn waitChild(pid: i32) Err!u8 {
    var status: u32 = undefined;

    while (true) {
        switch (errno(linux.waitpid(pid, &status, 0))) {
            .SUCCESS => break,
            .INTR => continue,
            else => |e| errnoBug("waitpid", e),
        }
    }

    if (linux.W.IFEXITED(status)) {
        return linux.W.EXITSTATUS(status);
    } else {
        var cause: []const u8 = undefined;

        if (linux.W.IFSIGNALED(status)) {
            cause = @tagName(linux.W.TERMSIG(status));
        } else if (linux.W.IFSTOPPED(status)) {
            cause = @tagName(@as(linux.SIG, @enumFromInt(linux.W.STOPSIG(status))));
        } else {
            std.debug.panic("child exited with unknown outcome\n", .{});
        }

        std.debug.print("child exited with signal {s}\n", .{cause});
        return Err.Err;
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

fn sendAll(fd: i32, buf: []const u8) Err!void {
    var n_written: usize = 0;
    while (n_written < buf.len) {
        const write_rc = linux.write(fd, buf.ptr + n_written, buf.len - n_written);

        const n = try switch (errno(write_rc)) {
            .SUCCESS => write_rc,
            .INTR => continue,
            .INVAL,
            .AGAIN,
            .BADF,
            .NOTSOCK,
            => |e| errnoBug("write", e),
            .CONNRESET, .PIPE => logErr("connection closed by peer\n", .{}),
            else => |e| errnoUnexpected("write", e),
        };

        n_written += n;
    }
}

const ReadAllError = error{
    UnexpectedEof,
} || Err;

fn recvAll(fd: i32, buf: []u8) ReadAllError!void {
    var n_read: usize = 0;
    while (n_read < buf.len) {
        const read_rc = linux.read(fd, buf[n_read..].ptr, buf.len - n_read);
        const n = try switch (errno(read_rc)) {
            .SUCCESS => if (read_rc == 0) ReadAllError.UnexpectedEof else read_rc,
            .INTR => continue,
            .PIPE, .CONNRESET => logErr("connection reset by peer\n", .{}),
            .AGAIN,
            .BADF,
            .FAULT,
            .INVAL,
            .ISDIR,
            .NOTSOCK,
            => |e| errnoBug("read", e),
            else => |e| errnoUnexpected("read", e),
        };
        n_read += n;
    }
}

fn cpuNSet(n: i32) Err!linux.cpu_set_t {
    var set = std.mem.zeroes(linux.cpu_set_t);
    try setCpuset(&set, n);
    return set;
}

fn setCpuset(set: *linux.cpu_set_t, n: i32) Err!void {
    const Elem = @typeInfo(linux.cpu_set_t).array.child;

    const nu = std.math.cast(u32, n) orelse return logErr("invalid cpu number: {}\n", .{n});

    const index = nu / @bitSizeOf(Elem);
    if (index >= (@sizeOf(linux.cpu_set_t) / @sizeOf(Elem))) {
        return logErr("cpu number out of bounds: {}\n", .{n});
    }

    const pos: @Int(.unsigned, std.math.log2(@bitSizeOf(Elem))) = @intCast(nu % @bitSizeOf(Elem));
    const one: Elem = 1;
    const mask = one << pos;
    set[index] |= mask;
}

fn errnoBug(call: []const u8, e: linux.E) noreturn {
    std.debug.panic("errno bug when calling {s}: {t}\n", .{ call, e });
}

fn errnoUnexpected(call: []const u8, e: linux.E) Err {
    std.debug.print("unexpected errno when calling {s}: {t}\n", .{ call, e });
    return Err.Err;
}

fn logErr(comptime fmt: []const u8, args: anytype) Err {
    std.debug.print(fmt, args);
    return Err.Err;
}

test "setCpuset" {
    var set = std.mem.zeroes(linux.cpu_set_t);
    try setCpuset(&set, 7);
    try testing.expectEqual(1, linux.CPU_COUNT(set));
    try testing.expectEqual(128, set[0]);
    set = std.mem.zeroes(linux.cpu_set_t);
    try testing.expectError(Err.Err, setCpuset(&set, std.math.maxInt(i32)));
}
