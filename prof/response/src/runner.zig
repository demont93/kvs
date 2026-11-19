const std = @import("std");
const builtin = @import("builtin");
const build_info = @import("build_info");
const linux = std.os.linux;
const errno = linux.errno;
const panic = std.debug.panic;
const ArenaAllocator = std.heap.ArenaAllocator;
const process = std.process;
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const lib = @import("lib.zig");
const errnoBug = lib.errnoBug;
const logErr = lib.logErr;
const Err = lib.Err;
const LoadGen = @import("LoadGen.zig");
const srv = @import("srv.zig");

pub const Run = struct {
    requests: usize,
    key_count: usize,
    seed: usize,
    cpu1: i32,
    cpu2: i32,
    port: u16,
    ops: Ops,
    p_args: []const u8,
};

pub const Ops = std.EnumSet(LoadGen.Op);

const MeasurementType = enum {
    profile,
    count,
};

const Measurement = struct {
    // fd slot numbers
    const fd_lgen = 0;
    const fd_serv = 1;
    const fd_perf = 2;

    server_handle: ServerHandle,
    lg_handle: LoadGenHandle,
    measurement_type: MeasurementType,
    measurement_dir: *Report.MeasurementDir,
    p_args: []const u8,

    const Options = struct {
        port: u16,
        cpu1: linux.cpu_set_t,
        cpu2: linux.cpu_set_t,
        measurement_type: MeasurementType,
        measurement_dir: *Report.MeasurementDir,
        p_args: []const u8,
        workload: LoadGen.Workload,
        lgen_init: InitOptions,
        serv_init: InitOptions,
        perf_init: InitOptions,
    };

    fn init(
        self: *Measurement,
        opts: Options,
    ) Err!void {
        errdefer logErr("initializing measurement execution\n", .{}) catch {};

        self.measurement_type = opts.measurement_type;
        self.measurement_dir = opts.measurement_dir;
        self.p_args = opts.p_args;

        self.lg_handle = try LoadGenHandle.init(opts.cpu1, opts.port, opts.workload, opts.lgen_init);

        self.server_handle = ServerHandle.init(
            opts.port,
            opts.cpu2,
            opts.measurement_type,
            opts.serv_init,
        ) catch |e| {
            self.lg_handle.kill();
            return e;
        };
    }

    fn wait(self: *Measurement) Err!void {
        errdefer logErr("waiting for measurement children\n", .{}) catch {};

        const lgen_result = self.lg_handle.wait();
        const serv_result = self.server_handle.close();

        try lgen_result;
        try serv_result;
    }

    fn kill(self: *Measurement) void {
        logErr("killing test children\n", .{}) catch {};
        self.lg_handle.kill();
        self.server_handle.close() catch {};
    }

    fn run(self: *Measurement, io: Io, arena: *ArenaAllocator, perf_opts: InitOptions) !void {
        errdefer logErr("{t} measurement failed\n", .{self.measurement_type}) catch {};

        const perf_op: Perf.OpArgs = switch (self.measurement_type) {
            .count => .{ .trace = try self.measurement_dir.traceFilename() },
            .profile => .{ .record = .{
                .filename = try self.measurement_dir.recordFilename(),
                .p_args = self.p_args,
            } },
        };

        var perf = try Perf.init(io, arena, self.server_handle.pid, perf_op, perf_opts);

        {
            errdefer perf.kill(io);

            var poll_fds: [3]linux.pollfd = undefined;
            self.initPollFds(perf, &poll_fds);

            try self.server_handle.awaitReady();

            try self.lg_handle.connect();

            try self.lg_handle.awaitReady();

            self.server_handle.start(self.measurement_type);
            try perf.enable();
            try self.lg_handle.start();

            _ = try poll(&poll_fds);

            try perf.stop();
            try self.lg_handle.awaitDone();
            self.server_handle.end(self.measurement_type);

            switch (self.measurement_type) {
                .profile => {},
                .count => try self.awaitReport(io),
            }
        }

        try perf.wait(io);
    }

    fn awaitReport(self: *Measurement, io: Io) !void {
        var report: srv.Report = undefined;
        try self.server_handle.awaitResult(&report);
        const f = try self.measurement_dir.allocsFile();
        errdefer self.measurement_dir.deleteAllocsFile() catch {
            std.debug.print("cleaning up allocs file\n", .{});
        };
        try Report.writeAllocReport(io, f, report);
    }

    fn initPollFds(self: Measurement, perf: Perf, poll_fds: *[3]linux.pollfd) void {
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

    fn measure(io: Io, arena: *ArenaAllocator, opts: Measurement.Options) Err!void {
        var measurement: Measurement = undefined;

        try measurement.init(opts);

        {
            errdefer measurement.kill();
            measurement.run(io, arena, opts.perf_init) catch return Err.Err;
        }

        try measurement.wait();
    }
};

const InitOptions = struct {
    init: union(enum) {
        test_spawn: CloneTarget,
        default,
    } = .{ .default = {} },
};

const ServerHandle = struct {
    pid: i32,
    sock: i32,
    measurement_type: MeasurementType,
    status: enum { running, done, unknown } = .running,

    fn init(
        port: u16,
        cpu: linux.cpu_set_t,
        test_type: MeasurementType,
        opts: InitOptions,
    ) Err!ServerHandle {
        errdefer logErr("opening server\n", .{}) catch {};

        const socks = try lib.socketPair();

        const ctx: srv.Context = .{
            .count_allocs = switch (test_type) {
                .count => true,
                .profile => false,
            },
            .cpu = cpu,
            .port = port,
            .sock = socks[1],
        };

        const spawn_func = switch (opts.init) {
            .default => &srv.processMain,
            .test_spawn => |v| v,
        };

        const pid = lib.clone(@constCast(&ctx), spawn_func) catch |e| {
            lib.closeFdLog(socks[0]);
            lib.closeFdLog(socks[1]);
            return e;
        };

        lib.closeFd(socks[1]) catch |e| {
            lib.closeFdLog(socks[0]);
            lib.killChild(pid);
            return e;
        };

        return ServerHandle{ .pid = pid, .sock = socks[0], .measurement_type = .profile };
    }

    fn close(self: *ServerHandle) Err!void {
        errdefer logErr("closing server\n", .{}) catch {};

        return switch (self.status) {
            .running => self.terminateWait(),
            .done => self.wait(),
            .unknown => self.kill(),
        };
    }

    fn awaitReady(self: *ServerHandle) Err!void {
        errdefer logErr("awaiting ready\n", .{}) catch {};
        var buf: [1]u8 = undefined;
        recvAll(self.sock, &buf) catch |err| {
            switch (err) {
                error.UnexpectedEof => self.status = .done,
                error.Err => self.status = .unknown,
            }
            return error.Err;
        };
        if (buf[0] != @intFromEnum(srv.Message.ready)) {
            return logErr("received wrong message\n", .{});
        }
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

    fn terminateWait(self: *ServerHandle) Err!void {
        self.terminate();
        try self.wait();
    }

    fn start(self: *ServerHandle, measurement_type: MeasurementType) void {
        if (measurement_type == .count) {
            switch (errno(linux.kill(self.pid, .USR1))) {
                .SUCCESS => {},
                else => |e| errnoBug("kill", e),
            }
        }
    }

    fn terminate(self: *ServerHandle) void {
        self.status = .done;
        switch (errno(linux.kill(self.pid, .INT))) {
            .SUCCESS => {},
            else => |e| errnoBug("kill", e),
        }
    }

    fn end(self: *ServerHandle, measurement_type: MeasurementType) void {
        if (measurement_type == .count) {
            switch (errno(linux.kill(self.pid, .USR2))) {
                .SUCCESS => {},
                else => |e| errnoBug("kill", e),
            }
        }
        self.terminate();
    }

    fn startCounting(self: *ServerHandle) Err!void {
        const msg = @intFromEnum(srv.Message.start_counting);
        try sendAll(self.sock, @as(*const [1]u8, &msg));
    }

    fn wait(self: *ServerHandle) Err!void {
        errdefer logErr("waiting for server pid\n", .{}) catch {};

        const code = try waitHandle(&self.pid, &self.sock);

        switch (@as(srv.ExitCode, @enumFromInt(code))) {
            .success => {},
            .err => return logErr("received err exit code\n", .{}),
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

    fn init(
        cpu: linux.cpu_set_t,
        port: u16,
        workload: LoadGen.Workload,
        opts: InitOptions,
    ) Err!LoadGenHandle {
        errdefer logErr("opening load generator\n", .{}) catch {};

        const socks = try lib.socketPair();

        const ctx: LoadGen.Context = .{
            .cpu = cpu,
            .sock = socks[1],
            .workload = workload,
            .port = port,
        };

        const spawn_func = switch (opts.init) {
            .default => &LoadGen.processMain,
            .test_spawn => |v| v,
        };

        const pid = lib.clone(@constCast(&ctx), spawn_func) catch |e| {
            lib.closeFdLog(socks[0]);
            lib.closeFdLog(socks[1]);
            return e;
        };

        lib.closeFd(socks[1]) catch |e| {
            lib.closeFdLog(socks[0]);
            lib.killChild(pid);
            return e;
        };

        return LoadGenHandle{ .sock = socks[0], .pid = pid };
    }

    fn awaitDone(self: *LoadGenHandle) Err!void {
        errdefer logErr("awaiting done message from load generator\n", .{}) catch {};
        return switch (try self.recvCode()) {
            .err => logErr("received err message\n", .{}),
            .done => {},
            else => |m| invalidMessageReceived(m),
        };
    }

    /// Messages the Load Generator to connect and start warmup phase.
    fn connect(self: *LoadGenHandle) Err!void {
        errdefer logErr("sending connect to load generator\n", .{}) catch {};

        const msg = @intFromEnum(LoadGen.Message.connect);
        try sendAll(self.sock, @as(*const [1]u8, &msg));
    }

    fn awaitReady(self: *LoadGenHandle) Err!void {
        errdefer logErr("awaiting ready message from load generator\n", .{}) catch {};
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

        const msg = @intFromEnum(LoadGen.Message.start);
        try sendAll(self.sock, @as(*const [1]u8, &msg));
    }

    fn recvCode(self: *LoadGenHandle) Err!LoadGen.Message {
        var buf: [1]u8 = undefined;

        recvAll(self.sock, &buf) catch return Err.Err;

        const msg = std.enums.fromInt(LoadGen.Message, buf[0]) orelse
            panic("invalid message from load generator: {}\n", .{buf[0]});

        return switch (msg) {
            .err, .ready, .done, .connect => |e| e,
            .start => |m| invalidMessageReceived(m),
        };
    }

    fn invalidMessageReceived(msg: LoadGen.Message) noreturn {
        panic("invalid message from load generator: {t}", .{msg});
    }

    fn wait(self: *LoadGenHandle) Err!void {
        errdefer logErr("waiting for load generator pid\n", .{}) catch {};

        const code = waitHandle(&self.pid, &self.sock) catch return Err.Err;
        switch (@as(LoadGen.ExitCode, @enumFromInt(code))) {
            .success => {},
            .err => return logErr("received err exit code\n", .{}),
        }
    }

    fn kill(self: *LoadGenHandle) void {
        std.debug.print("load generator process killed\n", .{});
        return killHandle(&self.pid, &self.sock);
    }
};

const Perf = struct {
    const ack = "ack\n" ++ .{0};

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
                lib.closeFdLog(pipes1[0]);
                lib.closeFdLog(pipes1[1]);
            }
            const pipes2 = try makePipe();

            return .{
                .my_r = pipes1[0],
                .my_w = pipes2[1],
                .their_r = pipes2[0],
                .their_w = pipes1[1],
            };
        }

        fn noCloExecTheirs(self: PipePairs) Err!void {
            try lib.noCloexec(self.their_r);
            try lib.noCloexec(self.their_w);
        }

        fn closeMineLog(self: *PipePairs) void {
            lib.closeFdLog(self.my_r);
            lib.closeFdLog(self.my_w);
        }

        fn closeTheirs(self: *PipePairs) Err!void {
            const r1 = lib.closeFd(self.their_r);
            const r2 = lib.closeFd(self.their_w);

            try r1;
            try r2;
        }
    };

    const TestCtx = struct {
        ack_pipe: i32,
        ctl_pipe: i32,
    };

    const Op = enum { record, trace };

    const OpArgs = union(Op) {
        record: struct {
            filename: []const u8,
            p_args: []const u8,
        },
        trace: []const u8,
    };

    fn init(
        io: Io,
        arena: *ArenaAllocator,
        pid: i32,
        op: OpArgs,
        opts: InitOptions,
    ) Err!Perf {
        errdefer {
            switch (op) {
                .trace => logErr("tracing with perf\n", .{}) catch {},
                .record => logErr("recording with perf\n", .{}) catch {},
            }
        }

        var pipe_pairs: PipePairs = try .init();
        errdefer pipe_pairs.closeMineLog();

        var child: process.Child = blk: {
            errdefer pipe_pairs.closeTheirs() catch {};

            try pipe_pairs.noCloExecTheirs();

            switch (opts.init) {
                .default => {
                    switch (op) {
                        .record => |v| {
                            const args = recordArgs(
                                arena,
                                try pidStr(arena, pid),
                                try controlFdArg(arena, pipe_pairs.their_r, pipe_pairs.their_w),
                                v.filename,
                                v.p_args,
                            ) catch |err| return logErr("error creating perf record args: {t}\n", .{err});

                            break :blk process.spawn(io, .{ .argv = args }) catch |err| switch (err) {
                                else => |e| return logErr("failed to spawn perf: {t}\n", .{e}),
                            };
                        },
                        .trace => |v| {
                            const args = traceArgs(
                                try pidStr(arena, pid),
                                try controlFdArg(arena, pipe_pairs.their_r, pipe_pairs.their_w),
                                v,
                            );
                            break :blk process.spawn(io, .{ .argv = &args }) catch |err| switch (err) {
                                else => |e| return logErr("failed to spawn perf: {t}\n", .{e}),
                            };
                        },
                    }
                },
                .test_spawn => |v| {
                    const ctx: TestCtx = .{
                        .ack_pipe = pipe_pairs.their_w,
                        .ctl_pipe = pipe_pairs.their_r,
                    };
                    const child_pid = try lib.clone(@constCast(&ctx), v);
                    break :blk process.Child{
                        .id = child_pid,
                        .request_resource_usage_statistics = false,
                        .thread_handle = {},
                        .stderr = null,
                        .stdin = null,
                        .stdout = null,
                    };
                },
            }
        };
        errdefer child.kill(io);

        try pipe_pairs.closeTheirs();

        return .{
            .child_proc = child,
            .ack_pipe = pipe_pairs.my_r,
            .ctl_pipe = pipe_pairs.my_w,
        };
    }

    fn recordArgs(
        arena: *ArenaAllocator,
        pid_str: []const u8,
        ctl_fd_str: []const u8,
        filename: []const u8,
        p_args: []const u8,
    ) ![][]const u8 {
        const default = [_][]const u8{
            "perf",
            "record",
            "-g",
            "-p",
            pid_str,
            "--delay=-1",
            ctl_fd_str,
            "-o",
            filename,
        };

        var lst = try std.ArrayList([]const u8).initCapacity(arena.allocator(), default.len);
        try lst.appendSlice(arena.allocator(), &default);

        var it = mem.tokenizeScalar(u8, p_args, ' ');
        while (it.next()) |tok| {
            try lst.append(arena.allocator(), tok);
        }

        return lst.items;
    }

    fn traceArgs(
        pid_str: []const u8,
        ctl_fd_str: []const u8,
        filename: []const u8,
    ) [11][]const u8 {
        return [_][]const u8{
            "perf",
            "stat",
            "-x,",
            "-e",
            "syscalls:sys_enter_*",
            "-p",
            pid_str,
            "--delay=-1",
            ctl_fd_str,
            "-o",
            filename,
        };
    }

    fn wait(self: *Perf, io: Io) Err!void {
        errdefer logErr("waiting for perf pid\n", .{}) catch {};

        switch (errno(linux.kill(self.child_proc.id.?, linux.SIG.INT))) {
            .SUCCESS => {},
            else => |e| errnoBug("kill", e),
        }

        // There is a gap on the current standard where if io gets canceled, it leaks the
        // process. Store the pid and signal it on error to avoid leaks.
        const child_pid = self.child_proc.id.?;

        const termination = timeoutWait(io, &self.child_proc) catch |err| {
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

        lib.closeFdLog(self.ack_pipe);
        const write_pipe_close_result = lib.closeFd(self.ctl_pipe);

        switch (termination) {
            .exited => |v| if (v != 0) return logErr("perf exited with error\n", .{}),
            .signal => |v| if (v != .INT) return logErr("perf exited with signal: {t}\n", .{v}),
            else => return logErr("perf exited ungracefully\n", .{}),
        }
        try write_pipe_close_result;
    }

    fn timeoutWait(io: Io, child: *process.Child) error{Canceled}!process.Child.Term {
        const SelectResult = union(enum) {
            timeout: error{Canceled}!void,
            wait: process.Child.WaitError!process.Child.Term,
        };
        const Select = Io.Select(SelectResult);

        var buf: [2]SelectResult = undefined;
        var s = Select.init(io, &buf);

        s.concurrent(
            .timeout,
            Io.sleep,
            .{ io, .fromSeconds(10), .awake },
        ) catch |e| panic("{t}\n", .{e});

        s.concurrent(
            .wait,
            process.Child.wait,
            .{ child, io },
        ) catch |e| panic("{t}\n", .{e});

        const result = try s.await();

        if (s.cancel()) |r| switch (r) {
            .wait => |v| return v catch |e| handleWaitError(e),
            else => {},
        };

        switch (result) {
            .timeout => return error.Canceled,
            .wait => |v| return v catch |e| handleWaitError(e),
        }
    }

    fn handleWaitError(err: process.Child.WaitError) error{Canceled} {
        switch (err) {
            error.Canceled => |e| return e,
            error.AccessDenied => panic("access denied while waiting for prof pid\n", .{}),
            error.Unexpected => panic("unexpected zig std lib syscall error\n", .{}),
        }
    }

    fn kill(self: *Perf, io: Io) void {
        lib.closeFdLog(self.ack_pipe);
        lib.closeFdLog(self.ctl_pipe);
        self.child_proc.kill(io);
    }

    fn enable(self: *Perf) Err!void {
        errdefer logErr("enabling perf\n", .{}) catch {};
        try self.send_msg("enable");
    }

    fn stop(self: *Perf) !void {
        errdefer logErr("stopping perf\n", .{}) catch {};
        try self.send_msg("disable");
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
};

const Report = struct {
    const root_dirname = "reports";
    const meta_filename = "meta.txt";

    io: Io,
    id_str: []const u8,
    dir: Io.Dir,
    run_start: Io.Clock.Timestamp,

    const MeasurementDir = struct {
        const allocs_head = "allocs.txt";

        io: Io,
        arena: ArenaAllocator,
        dir: Io.Dir,

        fn init(
            io: Io,
            allocator: Allocator,
            reports_dir: Io.Dir,
            op: LoadGen.Op,
        ) !MeasurementDir {
            const head = op.formatted();
            try reports_dir.createDir(io, head, .default_dir);
            errdefer reports_dir.deleteDir(io, head) catch {
                std.debug.print("error deleting measurement dir\n", .{});
            };

            return .{
                .dir = try reports_dir.openDir(io, head, .{}),
                .arena = ArenaAllocator.init(allocator),
                .io = io,
            };
        }

        fn recordFilename(self: *MeasurementDir) ![]u8 {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const size = try self.dir.realPath(self.io, &buf);
            return std.fs.path.join(self.arena.allocator(), &.{ buf[0..size], "perf.data" });
        }

        fn allocsFile(self: MeasurementDir) !Io.File {
            errdefer std.debug.print("creating allocs file\n", .{});
            return openCreateFileWrite(self.io, self.dir, allocs_head);
        }

        fn deleteAllocsFile(self: MeasurementDir) !void {
            return self.dir.deleteFile(self.io, allocs_head);
        }

        fn traceFilename(self: *MeasurementDir) ![]u8 {
            const trace_head = "trace.csv";
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const size = try self.dir.realPath(self.io, &buf);
            return std.fs.path.join(self.arena.allocator(), &.{ buf[0..size], trace_head });
        }

        fn deinit(self: MeasurementDir) void {
            self.arena.deinit();
        }
    };

    fn init(io: Io, arena: *ArenaAllocator, dir: ?[]const u8) !Report {
        const root_dir = try ensureRootDir(io, dir);
        defer root_dir.close(io);

        const now = Io.Clock.Timestamp.now(io, .real);
        const id_str = try idStr(arena, now);

        try root_dir.createDir(io, id_str, .default_dir);
        errdefer root_dir.deleteDir(io, id_str) catch {
            std.debug.print("cleaning up report dir\n", .{});
        };

        return .{
            .run_start = now,
            .io = io,
            .id_str = id_str,
            .dir = try root_dir.openDir(io, id_str, .{}),
        };
    }

    fn measurementDir(self: Report, allocator: Allocator, op: LoadGen.Op) !MeasurementDir {
        return .init(self.io, allocator, self.dir, op);
    }

    fn ensureRootDir(io: Io, dirpath: ?[]const u8) !Io.Dir {
        const dir = if (dirpath) |p| p else root_dirname;
        const cwd = Io.Dir.cwd();
        return cwd.createDirPathOpen(io, dir, .{});
    }

    fn openCreateFileWrite(io: Io, dir: Io.Dir, head: []const u8) !Io.File {
        return dir.createFile(io, head, .{});
    }

    fn utcTimeStr(timestamp: Io.Clock.Timestamp) ![20]u8 {
        assert(timestamp.clock == .real);

        const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(timestamp.raw.toSeconds()) };
        const ds = es.getDaySeconds();
        const ed = es.getEpochDay();
        const yd = ed.calculateYearDay();
        const md = yd.calculateMonthDay();

        var buf: [20]u8 = undefined;
        var w = Io.Writer.fixed(&buf);

        try w.print(
            "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
            .{
                yd.year,              md.month.numeric(),      md.day_index + 1,
                ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
            },
        );
        return buf;
    }

    fn idStr(arena: *ArenaAllocator, timestamp: Io.Clock.Timestamp) ![]u8 {
        const time_str = try utcTimeStr(timestamp);
        return std.fmt.allocPrint(arena.allocator(), "{s}-{s}", .{ time_str, build_info.git_hash });
    }

    const Meta = struct {
        run_success: bool,
        run_args: Run,
    };

    fn writeMeta(self: Report, arena: *ArenaAllocator, meta: Meta) !void {
        const f = try self.dir.createFile(self.io, meta_filename, .{});
        errdefer self.dir.deleteFile(self.io, meta_filename) catch {
            std.debug.print("cleaning up meta file\n", .{});
        };
        defer f.close(self.io);

        var r_buf: [256]u8 = undefined;

        var file_writer_buf: [256]u8 = undefined;
        var w = f.writer(self.io, &file_writer_buf);

        var uname: linux.utsname = undefined;
        switch (errno(linux.uname(&uname))) {
            .SUCCESS => {},
            else => |e| errnoBug("uname", e),
        }

        const run_start_str = try utcTimeStr(self.run_start);

        const cpu_info = try readFileStreaming(self.io, arena, "/proc/cpuinfo", &r_buf);

        const cpu_model_name = blk: {
            const start = std.mem.find(u8, cpu_info, "model name") orelse
                return logErr("couldn't find model name on cpuinfo\n", .{});
            const sep = start + std.mem.find(u8, cpu_info[start..], ":").?;
            const end = sep + 2 + std.mem.find(u8, cpu_info[sep + 2 ..], "\n").?;
            break :blk cpu_info[sep + 2 .. end];
        };

        const isolated = try readFile(self.io, arena, "/sys/devices/system/cpu/isolated", &r_buf);

        const no_turbo = try readFile(
            self.io,
            arena,
            "/sys/devices/system/cpu/intel_pstate/no_turbo",
            &r_buf,
        );

        const epp1 = try readFile(
            self.io,
            arena,
            try std.fmt.allocPrint(
                arena.allocator(),
                "/sys/devices/system/cpu/cpu{}/cpufreq/energy_performance_preference",
                .{meta.run_args.cpu1},
            ),
            &r_buf,
        );

        const epp2 = try readFile(
            self.io,
            arena,
            try std.fmt.allocPrint(
                arena.allocator(),
                "/sys/devices/system/cpu/cpu{}/cpufreq/energy_performance_preference",
                .{meta.run_args.cpu2},
            ),
            &r_buf,
        );

        const perf_version = blk: {
            var cmd = try std.process.spawn(
                self.io,
                .{ .argv = &.{ "perf", "-v" }, .stdout = .pipe },
            );
            var r = cmd.stdout.?.reader(self.io, &r_buf);
            const version_str = try r.interface.allocRemaining(
                arena.allocator(),
                .limited(1 << 10),
            );
            const term = try cmd.wait(self.io);
            if (term != .exited or term.exited != 0) {
                return error.PerfVersionFailed;
            }
            break :blk if (version_str.len > 1)
                version_str[0 .. version_str.len - 1]
            else
                version_str;
        };

        const ops = blk: {
            var it = meta.run_args.ops.iterator();
            var final = std.ArrayList(u8).empty;
            var sep = false;
            while (it.next()) |op| {
                if (sep) {
                    try final.append(arena.allocator(), ',');
                }
                try final.appendSlice(arena.allocator(), op.formatted());
                sep = true;
            }
            break :blk final.items;
        };

        try w.interface.print(
            \\run.id={s}
            \\run.started_utc={s}
            \\run.status={s}
            \\
            \\build.git_hash={s}
            \\build.git_dirty={}
            \\build.mode={s}
            \\build.zig={s}
            \\
            \\host.kernel={s}
            \\host.cpu={s}
            \\host.isolated={s}
            \\host.no_turbo={s}
            \\host.load_gen.affinity={}
            \\host.load_gen.epp={s}
            \\host.server.affinity={}
            \\host.server.epp={s}
            \\host.perf_version={s}
            \\
            \\workload.ops={s}
            \\workload.requests={}
            \\workload.key_count={}
            \\workload.seed={}
            \\
        ,
            .{
                self.id_str,
                run_start_str,
                if (meta.run_success) "success" else "error",
                build_info.git_hash_full,
                build_info.git_dirty,
                @tagName(builtin.mode),
                builtin.zig_version_string,
                mem.span(uname.release[0..].ptr),
                cpu_model_name,
                isolated,
                no_turbo,
                meta.run_args.cpu1,
                epp1,
                meta.run_args.cpu2,
                epp2,
                perf_version,
                ops,
                meta.run_args.requests,
                meta.run_args.key_count,
                meta.run_args.seed,
            },
        );
        try w.flush();
    }

    fn writeAllocReport(io: Io, f: Io.File, report: srv.Report) !void {
        var w_buf: [256]u8 = undefined;
        var w = f.writer(io, &w_buf);
        try w.interface.print(
            \\allocation_count={}
            \\remap_count={}
            \\resize_count={}
            \\
        ,
            .{ report.alloc_count, report.remap_count, report.resize_count },
        );
        try w.flush();
    }

    fn readFileStreaming(io: Io, arena: *ArenaAllocator, path: []const u8, buf: []u8) ![]u8 {
        const f = try Io.Dir.openFileAbsolute(io, path, .{});
        defer f.close(io);
        var r = f.readerStreaming(io, buf);
        return r.interface.allocRemaining(arena.allocator(), .limited(1 << 20));
    }

    fn readFile(io: Io, arena: *ArenaAllocator, path: []const u8, buf: []u8) ![]u8 {
        const f = try Io.Dir.openFileAbsolute(io, path, .{});
        defer f.close(io);
        var r = f.reader(io, buf);
        return r.interface.allocRemaining(arena.allocator(), .limited(1 << 20));
    }
};

const RunOptions = struct {
    serv_opts: InitOptions = .{},
    perf_opts: InitOptions = .{},
    lgen_opts: InitOptions = .{},
};

/// Asserts cpu1 and cpu2 are different and gte 0.
pub fn run(io: Io, gpa: Allocator, arena: *ArenaAllocator, cmd: Run) Err!void {
    var report_dir = Report.init(io, arena, null) catch |e| {
        std.debug.print("error initializing reports: {t}\n", .{e});
        return Err.Err;
    };

    return runInner(io, gpa, arena, cmd, &report_dir, .{});
}

/// Asserts cpu1 and cpu2 are different and gte 0.
pub fn runInner(
    io: Io,
    gpa: Allocator,
    arena: *ArenaAllocator,
    cmd: Run,
    report_dir: *Report,
    opts: RunOptions,
) Err!void {
    assert(cmd.cpu1 != cmd.cpu2);
    assert(cmd.cpu1 >= 0);
    assert(cmd.cpu2 >= 0);

    const cpu1 = try cpuNSet(cmd.cpu1);
    const cpu2 = try cpuNSet(cmd.cpu2);

    var op_iter = cmd.ops.iterator();

    const result = rslt: while (op_iter.next()) |op| {
        var measurement_dir = report_dir.measurementDir(gpa, op) catch |e| break e;
        defer measurement_dir.deinit();

        for (std.enums.values(MeasurementType)) |measurement_type| {
            Measurement.measure(io, arena, .{
                .cpu1 = cpu1,
                .cpu2 = cpu2,
                .port = cmd.port,
                .measurement_type = measurement_type,
                .measurement_dir = &measurement_dir,
                .workload = .{
                    .key_count = cmd.key_count,
                    .operation = op,
                    .requests = cmd.requests,
                    .seed = cmd.seed,
                },
                .lgen_init = opts.lgen_opts,
                .serv_init = opts.serv_opts,
                .perf_init = opts.perf_opts,
                .p_args = cmd.p_args,
            }) catch |e| {
                logErr("{t} {t} measurement failed\n", .{ op, measurement_type }) catch {};
                break :rslt e;
            };
        }
    };

    const write_meta_result = report_dir.writeMeta(arena, .{
        .run_args = cmd,
        .run_success = if (result) |_| true else |_| false,
    }) catch |e| blk: {
        std.debug.print("error writing meta: {t}\n", .{e});
        break :blk Err.Err;
    };

    result catch return Err.Err;
    write_meta_result catch return Err.Err;
}

fn waitHandle(pid: *i32, sock_fd: *i32) Err!u8 {
    const close_result = lib.closeFd(sock_fd.*);
    sock_fd.* = -1;
    const code = lib.waitChild(pid.*);
    pid.* = std.math.minInt(i32);

    _ = try code;
    _ = try close_result;

    return code;
}

fn killHandle(pid: *i32, sock_fd: *i32) void {
    lib.killChild(pid.*);
    pid.* = std.math.minInt(i32);
    lib.closeFdLog(sock_fd.*);
    sock_fd.* = -1;
}

fn sendAll(fd: i32, buf: []const u8) Err!void {
    lib.sendAll(fd, buf) catch |err| return switch (err) {
        error.Unexpected => Err.Err,
        error.ClosedByPeer => logErr("connection closed by peer\n", .{}),
    };
}

const ReadAllError = error{
    UnexpectedEof,
} || Err;

fn recvAll(fd: i32, buf: []u8) ReadAllError!void {
    return lib.recvAll(fd, buf) catch |err| switch (err) {
        error.ClosedByPeer => logErr("connection reset by peer\n", .{}),
        error.Unexpected => Err.Err,
        error.UnexpectedEof => |e| e,
    };
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

fn errnoUnexpected(call: []const u8, e: linux.E) Err {
    lib.errnoUnexpected(call, e) catch return Err.Err;
}

test "setCpuset" {
    var set = std.mem.zeroes(linux.cpu_set_t);
    try setCpuset(&set, 7);
    try testing.expectEqual(1, linux.CPU_COUNT(set));
    try testing.expectEqual(128, set[0]);
    set = std.mem.zeroes(linux.cpu_set_t);
    try testing.expectError(Err.Err, setCpuset(&set, std.math.maxInt(i32)));
}

test "happy path" {
    const run_cmd: Run = .{
        .port = 9999,
        .cpu1 = 1,
        .cpu2 = 2,
        .requests = 1000,
        .key_count = 500,
        .seed = 2349834,
        .ops = .initOne(.delete_hit),
        .p_args = &.{},
    };
    try testRun(run_cmd, &basicFakeServ, &basicFakeLgen, &basicFakePerf, false);
}

test "perf is killed if it hangs after stop ack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var perf = try Perf.init(
        testing.io,
        &arena,
        34,
        .{ .record = .{ .filename = "file.txt", .p_args = &.{} } },
        .{ .init = .{ .test_spawn = perfTestFunc(hangingFakePerf) } },
    );

    try perf.enable();
    try perf.stop();
    try testing.expectError(Err.Err, perf.wait(testing.io));
}

fn hangingFakePerf(t: *PerfTester) !void {
    try t.recvEnable();
    try t.sendAck();
    try t.recvStop();
    try t.sendAck();
    try testing.io.sleep(.fromSeconds(20), .awake);
}

fn basicFakeServ(arg: usize) callconv(.c) u8 {
    const ctx: *srv.Context = @ptrFromInt(arg);

    const sigaction = linux.Sigaction{
        .flags = 0,
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = linux.sigemptyset(),
    };
    switch (errno(linux.sigaction(.USR1, &sigaction, null))) {
        .SUCCESS => {},
        else => |e| errnoBug("sigaction", e),
    }
    switch (errno(linux.sigaction(.USR2, &sigaction, null))) {
        .SUCCESS => {},
        else => |e| errnoBug("sigaction", e),
    }

    var restore_sigset: linux.sigset_t = undefined;
    var sigset = linux.sigemptyset();
    linux.sigaddset(&sigset, .INT);

    switch (errno(linux.sigprocmask(linux.SIG.BLOCK, &sigset, &restore_sigset))) {
        .SUCCESS => {},
        else => |e| errnoBug("sigprocmask", e),
    }

    sendAll(ctx.sock, &[_]u8{@intFromEnum(srv.Message.ready)}) catch {
        return srv.ExitCode.err.value();
    };

    switch (errno(linux.syscall4(
        .rt_sigtimedwait,
        @intFromPtr(&sigset),
        0,
        0,
        @sizeOf(linux.sigset_t),
    ))) {
        .SUCCESS => {},
        else => |e| errnoBug("sigtimedwait", e),
    }

    switch (errno(linux.sigprocmask(linux.SIG.SETMASK, &restore_sigset, null))) {
        .SUCCESS => {},
        else => |e| errnoBug("sigprocmask", e),
    }

    const report = srv.Report{
        .alloc_count = 234,
        .remap_count = 234,
        .resize_count = 234,
    };
    const result_msg: *const [@sizeOf(srv.Report)]u8 = @ptrCast(&report);

    sendAll(ctx.sock, result_msg) catch {
        return srv.ExitCode.err.value();
    };

    return srv.ExitCode.success.value();
}

fn basicFakeLgen(arg: usize) callconv(.c) u8 {
    const ctx: *LoadGen.Context = @ptrFromInt(arg);

    const ready_msg: [1]u8 = .{@intFromEnum(LoadGen.Message.ready)};
    const done_msg: [1]u8 = .{@intFromEnum(LoadGen.Message.done)};
    const start_msg: [1]u8 = .{@intFromEnum(LoadGen.Message.start)};

    var buf: [1]u8 = undefined;

    recvAll(ctx.sock, &buf) catch {
        return LoadGen.ExitCode.err.value();
    };

    sendAll(ctx.sock, &ready_msg) catch {
        return LoadGen.ExitCode.err.value();
    };

    recvAll(ctx.sock, &buf) catch {
        return LoadGen.ExitCode.err.value();
    };
    testing.expectEqualSlices(u8, &start_msg, &buf) catch {
        return LoadGen.ExitCode.err.value();
    };

    sendAll(ctx.sock, &done_msg) catch {
        return LoadGen.ExitCode.err.value();
    };

    return LoadGen.ExitCode.success.value();
}

fn perfTestFunc(
    comptime f: fn (*PerfTester) anyerror!void,
) CloneTarget {
    return struct {
        fn do(arg: usize) callconv(.c) u8 {
            var t: PerfTester = undefined;
            t.init(arg);

            if (f(&t)) |_| {
                return 0;
            } else |_| {
                return 1;
            }
        }
    }.do;
}

fn basicFakePerf(arg: usize) callconv(.c) u8 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const ctx: *Perf.TestCtx = @ptrFromInt(arg);

    var buf_r: [256]u8 = undefined;
    var buf_w: [256]u8 = undefined;

    var ack_pipe = Io.File{ .flags = .{ .nonblocking = false }, .handle = ctx.ack_pipe };
    var ctl_pipe = Io.File{ .flags = .{ .nonblocking = false }, .handle = ctx.ctl_pipe };

    var ack_w = ack_pipe.writer(testing.io, &buf_w);
    var ctl_r = ctl_pipe.reader(testing.io, &buf_r);

    var buf: [6]u8 = undefined;

    ctl_r.interface.readSliceAll(&buf) catch {
        return 1;
    };
    testing.expectEqualSlices(u8, "enable", &buf) catch {
        return 1;
    };

    ack_w.interface.writeAll(Perf.ack) catch {
        return 1;
    };
    ack_w.interface.flush() catch {
        return 1;
    };

    ctl_r.interface.readSliceAll(buf[0..4]) catch {
        return 1;
    };
    testing.expectEqualSlices(u8, "stop", buf[0..4]) catch {
        return 1;
    };

    ack_w.interface.writeAll(Perf.ack) catch {
        return 1;
    };
    ack_w.interface.flush() catch {
        return 1;
    };

    return 0;
}

fn testRun(
    cmd: Run,
    fakeServFunc: CloneTarget,
    fakeLgenFunc: CloneTarget,
    fakePerfFunc: CloneTarget,
    err: bool,
) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var temp = testing.tmpDir(.{});
    defer temp.cleanup();

    var temp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_size = try temp.dir.realPath(testing.io, &temp_path_buf);

    var report_dir = Report.init(testing.io, &arena, temp_path_buf[0..path_size]) catch |e| {
        std.debug.print("error initializing reports: {t}\n", .{e});
        return Err.Err;
    };

    if (err) {
        try testing.expectError(Err.Err, runInner(
            testing.io,
            testing.allocator,
            &arena,
            cmd,
            &report_dir,
            .{
                .lgen_opts = .{ .init = .{ .test_spawn = fakeLgenFunc } },
                .perf_opts = .{ .init = .{ .test_spawn = fakePerfFunc } },
                .serv_opts = .{ .init = .{ .test_spawn = fakeServFunc } },
            },
        ));
    } else {
        try runInner(
            testing.io,
            testing.allocator,
            &arena,
            cmd,
            &report_dir,
            .{
                .lgen_opts = .{ .init = .{ .test_spawn = fakeLgenFunc } },
                .perf_opts = .{ .init = .{ .test_spawn = fakePerfFunc } },
                .serv_opts = .{ .init = .{ .test_spawn = fakeServFunc } },
            },
        );
    }
}

const CloneTarget = *const fn (arg: usize) callconv(.c) u8;

const PerfTester = struct {
    arena: ArenaAllocator,
    ctl_pipe: Io.File,
    ack_pipe: Io.File,
    buf_r: [256]u8 = undefined,
    buf_w: [256]u8 = undefined,
    ctl_r: Io.File.Reader,
    ack_w: Io.File.Writer,

    fn init(self: *PerfTester, arg: usize) void {
        const ctx: *Perf.TestCtx = @ptrFromInt(arg);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.ack_pipe = Io.File{ .flags = .{ .nonblocking = false }, .handle = ctx.ack_pipe };
        self.ctl_pipe = Io.File{ .flags = .{ .nonblocking = false }, .handle = ctx.ctl_pipe };
        self.ack_w = self.ack_pipe.writerStreaming(testing.io, &self.buf_w);
        self.ctl_r = self.ctl_pipe.readerStreaming(testing.io, &self.buf_r);
    }

    fn close(self: *PerfTester) !void {
        self.arena.deinit();
        self.ack_pipe.close(testing.io);
        self.ctl_pipe.close(testing.io);
    }

    fn sendAck(self: *PerfTester) !void {
        try self.ack_w.interface.writeAll(Perf.ack);
        try self.ack_w.interface.flush();
    }

    fn recvEnable(self: *PerfTester) !void {
        var buf: [6]u8 = undefined;
        try self.ctl_r.interface.readSliceAll(&buf);
        try testing.expectEqualSlices(u8, "enable", &buf);
    }

    fn recvStop(self: *PerfTester) !void {
        var buf: [4]u8 = undefined;
        try self.ctl_r.interface.readSliceAll(&buf);
        try testing.expectEqualSlices(u8, "stop", &buf);
    }
};
