const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const linux = std.os.linux;
const Duration = std.Io.Duration;
const Clock = std.Io.Clock;
const errno = linux.errno;
const testing = std.testing;
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const Thread = std.Thread;
const Stream = net.Stream;
const Server = net.Server;
const Ip4Address = net.Ip4Address;
const IpAddress = net.IpAddress;
const Writer = Io.Writer;
const Reader = Io.Reader;

const protocol = @import("protocol.zig");
const syscall = @import("syscall.zig");

const Self = @This();

const retry_connect_delay: Duration = .fromMilliseconds(100);

io: Io,
addr: linux.sockaddr.in,
sock_fd: i32,
timeout: Duration,
idle_timeout: Duration,
last_request: Clock.Timestamp,
max_attempts: i32,

const ConnState = enum {
    ok,
    conn_failed,
    error_before_write,
    error_after_write,
    timeout,
    fatal,
};

const Request = struct {
    op: protocol.Op,
    conn_state: ConnState,
    attempts: i32,
    max_attempts: i32,
    deadline: Clock.Timestamp,
    err: RequestError,

    fn init(op: protocol.Op, max_attempts: i32, deadline: Clock.Timestamp) Request {
        return .{
            .deadline = deadline,
            .conn_state = .ok,
            .attempts = 0,
            .max_attempts = max_attempts,
            .err = undefined,
            .op = op,
        };
    }

    fn next(self: *Request) bool {
        if (self.attempts >= self.max_attempts) {
            return false;
        }

        const retval = switch (self.conn_state) {
            .error_before_write, .conn_failed => true,
            .error_after_write => self.op.is_read_only(),
            .timeout, .fatal => false,
            .ok => true,
        };

        if (retval) self.attempts += 1;

        return retval;
    }

    fn set(self: *Request, state: ConnState, err: RequestError) void {
        self.conn_state = state;
        self.err = err;
    }

    fn get_error(self: Request) RequestError {
        return if (self.conn_state == .error_after_write and !self.op.is_read_only())
            error.UnknownOutcome
        else
            return self.err;
    }

    fn log_err(self: *Request, err: anytype) void {
        std.debug.print(
            "Client error: Op {t}, attempt {}: {t}\n",
            .{ self.op, self.attempts, err },
        );
    }

    fn check_deadline(self: *Request, io: Io) error{Timeout}!void {
        if (Clock.Timestamp.now(io, .awake).compare(.gte, self.deadline)) {
            return error.Timeout;
        }
    }
};

pub const Response = struct {
    code: protocol.ResponseCode = .Internal,
    value: []u8 = &.{},

    pub fn deinit(self: *Response, allocator: Allocator) void {
        allocator.free(self.value);
    }
};

pub const ClientOpts = struct {
    timeout: Duration = .fromSeconds(6),
    idle_timeout: Duration = .fromSeconds(8),
    max_attempts: i32 = 3,
};

pub fn init(
    self: *Self,
    io: Io,
    addr: []const u8,
    opts: ClientOpts,
) error{InvalidAddress}!void {
    self.io = io;
    self.last_request = undefined;
    self.addr = syscall.parse_addr(addr) orelse return error.InvalidAddress;
    self.sock_fd = -1;
    self.timeout = opts.timeout;
    self.idle_timeout = opts.idle_timeout;
    self.max_attempts = if (opts.max_attempts >= 1)
        opts.max_attempts
    else
        std.debug.panic("invalid client max attempts {} must be >= 1\n", .{opts.max_attempts});
}

pub const GetError = protocol.encode.KeyError || RequestError;

pub fn get(self: *Self, allocator: Allocator, key: []const u8) GetError!Response {
    try protocol.encode.check_key(key);
    var frame: [9]u8 = undefined;
    var bufs: [3][]const u8 = undefined;
    protocol.encode.encode_client_msg(.get, &frame, key, &.{}, &bufs);
    return self.do_request(allocator, .get, &bufs);
}

pub const SetError = protocol.encode.KeyError || protocol.encode.ValueError || RequestError;

pub fn set(self: *Self, key: []const u8, value: []const u8) SetError!Response {
    try protocol.encode.check_key(key);
    try protocol.encode.check_value(value);
    var frame: [9]u8 = undefined;
    var bufs: [3][]const u8 = undefined;
    protocol.encode.encode_client_msg(.set, &frame, key, value, &bufs);
    return self.do_request(null, .set, &bufs);
}

pub const DelError = protocol.encode.KeyError || RequestError;

pub fn del(self: *Self, key: []const u8) DelError!Response {
    try protocol.encode.check_key(key);
    var frame: [9]u8 = undefined;
    var bufs: [3][]const u8 = undefined;
    protocol.encode.encode_client_msg(.del, &frame, key, &.{}, &bufs);
    return self.do_request(null, .del, &bufs);
}

const RequestError = error{
    PermissionDenied,
    /// An error occurred after the request was written.
    UnknownOutcome,
    ConnectionError,
    /// Guarantees that the request was not sent.
    Timeout,
    Unexpected,
    Canceled,
};

fn do_request(
    self: *Self,
    allocator: ?Allocator,
    op: protocol.Op,
    data: *[3][]const u8,
) RequestError!Response {
    const deadline = self.create_deadline(self.timeout);
    var req: Request = .init(op, self.max_attempts, deadline);

    if (self.sock_fd >= 0 and self.idle_connection_is_expired()) {
        self.close_fd();
    }

    const result = while (req.next()) {
        const connect_result = switch (req.conn_state) {
            .ok => if (self.sock_fd == -1) self.connect(&req),
            .conn_failed => blk: {
                self.io.sleep(retry_connect_delay, .awake) catch |e| {
                    req.set(.fatal, e);
                    continue;
                };
                break :blk self.connect(&req);
            },
            else => self.reconnect(&req),
        };

        connect_result catch |err| {
            const state: ConnState = switch (err) {
                error.Unexpected, error.Timeout, error.PermissionDenied => .fatal,
                error.ConnectionError => .conn_failed,
            };
            req.set(state, err);
            continue;
        };

        self.writev_all(data, &req) catch |err| {
            const state: ConnState = switch (err) {
                error.Timeout => .timeout,
                error.ConnectionError => .error_before_write,
                error.Unexpected => .fatal,
            };
            req.set(state, err);
            continue;
        };

        break self.do_request_read_response(allocator, &req) catch |err| {
            const state: ConnState = switch (err) {
                error.Unexpected => .fatal,
                error.ConnectionError => .error_after_write,
            };
            req.set(state, err);
            continue;
        };
    } else req.get_error();

    if (result) |_| {
        self.last_request = self.now();
    } else |_| {
        if (self.sock_fd >= 0) {
            self.close_fd();
        }
    }

    return result;
}

const ConnectError = error{
    Timeout,
    PermissionDenied,
    ConnectionError,
    Unexpected,
};

fn connect(self: *Self, req: *Request) ConnectError!void {
    assert(self.sock_fd < 0);

    const socket_rc = syscall.socket(.NonBlocking);
    switch (errno(socket_rc)) {
        .SUCCESS => {},
        .INVAL, .PROTONOSUPPORT => |e2| syscall.errno_bug("socket", e2),
        else => |e| {
            req.log_err(e);
            switch (e) {
                .ACCES => return ConnectError.PermissionDenied,
                .NOBUFS,
                .NOMEM,
                .NFILE,
                .MFILE,
                => return ConnectError.ConnectionError,
                else => return ConnectError.Unexpected,
            }
        },
    }

    self.sock_fd = @intCast(socket_rc);

    errdefer self.close_fd();

    const connect_rc = linux.connect(self.sock_fd, &self.addr, @sizeOf(@TypeOf(self.addr)));
    switch (errno(connect_rc)) {
        .SUCCESS => return,
        // For a nonblocking socket, EINTR is the same as EINPROGRESS.
        .INTR, .INPROGRESS, .AGAIN => {},
        else => |e| return handle_connect_errno(req, e),
    }

    var unexpected: linux.E = undefined;
    var pollfds = [_]linux.pollfd{syscall.pollfd(self.sock_fd, linux.POLL.OUT)};
    _ = syscall.poll(self.io, &pollfds, req.deadline, &unexpected) catch |e| switch (e) {
        error.TooManyPollFds => syscall.zerrno_bug("poll", e),
        error.Unexpected => {
            req.log_err(unexpected);
            return error.Unexpected;
        },
        else => |e2| {
            req.log_err(e2);
            switch (e2) {
                error.OutOfMemory => return ConnectError.ConnectionError,
                else => |e3| return e3,
            }
        },
    };

    var raw_sock_err: i32 = 0;
    var sock_err_len: u32 = @sizeOf(i32);
    const gso_rc = linux.getsockopt(
        self.sock_fd,
        linux.SOL.SOCKET,
        linux.SO.ERROR,
        @ptrCast(&raw_sock_err),
        &sock_err_len,
    );
    switch (errno(gso_rc)) {
        .SUCCESS => {},
        else => |e| syscall.errno_bug("getsockopt", e),
    }

    const sock_err: linux.E = @enumFromInt(raw_sock_err);
    switch (sock_err) {
        .SUCCESS => {},
        else => |e| return handle_connect_errno(req, e),
    }
}

fn handle_connect_errno(req: *Request, err: linux.E) ConnectError {
    switch (err) {
        // Handled by caller
        .INTR, .AGAIN, .INPROGRESS => unreachable,

        .ADDRINUSE,
        .AFNOSUPPORT,
        .ALREADY,
        .BADF,
        .FAULT,
        .ISCONN,
        .NOTSOCK,
        .PROTOTYPE,
        => |e| syscall.errno_bug("connect", e),

        else => |e| {
            req.log_err(e);
            switch (e) {
                .PERM, .ACCES => return ConnectError.PermissionDenied,

                .NETUNREACH,
                .TIMEDOUT,
                .ADDRNOTAVAIL,
                .CONNREFUSED,
                => return ConnectError.ConnectionError,

                else => return ConnectError.Unexpected,
            }
        },
    }
}

const WriteError = error{
    Timeout,
    ConnectionError,
    Unexpected,
};

fn writev_all(self: *Self, data: *[3][]const u8, req: *Request) WriteError!void {
    var fds = syscall.pollfd(self.sock_fd, linux.POLL.OUT);
    var iovec_arr: [3]posix.iovec_const = undefined;
    const iovecs = blk: {
        var iovecs_len: usize = 0;
        for (data) |*s| {
            if (s.len == 0) continue;
            iovec_arr[iovecs_len].base = s.ptr;
            iovec_arr[iovecs_len].len = s.len;
            iovecs_len += 1;
        }
        break :blk iovec_arr[0..iovecs_len];
    };

    try req.check_deadline(self.io);

    while (true) {
        const writev_rc = linux.writev(self.sock_fd, iovecs.ptr, iovecs.len);
        var written: usize = switch (errno(writev_rc)) {
            .SUCCESS => @intCast(writev_rc),
            .AGAIN => 0,
            .INTR => continue,

            .NOTSOCK,
            .NOTCONN,
            .BADF,
            .ACCES,
            .ALREADY,
            .INVAL,
            .DESTADDRREQ,
            .ISCONN,
            .MSGSIZE,
            .OPNOTSUPP,
            .FAULT,
            => |e2| syscall.errno_bug("writev", e2),

            else => |e| {
                req.log_err(e);
                switch (e) {
                    .NOMEM, .PIPE, .CONNRESET => return error.ConnectionError,
                    else => return error.Unexpected,
                }
            },
        };

        if (written > 0) {
            for (iovecs) |*v| {
                if (written == 0) break;
                if (v.len == 0) continue;
                const min = @min(v.len, written);
                v.len -= min;
                v.base += min;
                written -= min;
            }
            if (iovecs[iovecs.len - 1].len == 0) {
                return;
            }
        }

        try req.check_deadline(self.io);

        var unexpected: linux.E = undefined;
        _ = syscall.poll(
            self.io,
            @as(*[1]linux.pollfd, &fds),
            req.deadline,
            &unexpected,
        ) catch |err| switch (err) {
            error.TooManyPollFds => |e| syscall.zerrno_bug("poll", e),
            error.Unexpected => {
                req.log_err(unexpected);
                return error.Unexpected;
            },
            else => |e| {
                req.log_err(e);
                switch (e) {
                    error.OutOfMemory => return error.ConnectionError,
                    error.Timeout => |e2| return e2,
                }
            },
        };
    }
}

const ReadResponseError = error{
    ConnectionError,
    Unexpected,
};

fn do_request_read_response(
    self: *Self,
    allocator: ?Allocator,
    req: *Request,
) ReadResponseError!Response {
    var frame: [5]u8 = undefined;

    try self.do_request_read_response_recv_all(req, &frame);

    var response: Response = .{};
    errdefer if (allocator) |a| response.deinit(a);

    if (std.enums.fromInt(protocol.ResponseCode, frame[0])) |res| {
        response.code = res;
    } else {
        return bad_response(req);
    }

    const len = std.mem.readInt(u32, frame[1..], .big);

    if (len > 0 and req.op != .get) {
        return bad_response(req);
    }

    if (len > protocol.max_value_size) {
        return bad_response(req);
    }

    if (len > 0) {
        response.value = allocator.?.alloc(u8, len) catch return error.ConnectionError;
        try self.do_request_read_response_recv_all(req, response.value);
    }

    return response;
}

fn bad_response(req: *Request) error{ConnectionError} {
    req.log_err(error.BadResponse);
    return error.ConnectionError;
}

fn do_request_read_response_recv_all(self: Self, req: *Request, buf: []u8) !void {
    var unexpected: linux.E = undefined;
    syscall.recv_all(
        self.sock_fd,
        buf,
        req.deadline,
        self.io,
        null,
        &unexpected,
    ) catch |err| switch (err) {
        error.Badf => syscall.zerrno_bug("read", err),
        error.Unexpected => {
            req.log_err(unexpected);
            return error.Unexpected;
        },
        else => |e| {
            req.log_err(e);
            return error.ConnectionError;
        },
    };
}

pub fn deinit(self: *Self) void {
    if (self.sock_fd < 0) {
        return;
    }

    self.close_fd();
}

fn reconnect(self: *Self, req: *Request) ConnectError!void {
    self.close_fd();
    try self.connect(req);
}

fn close_fd(self: *Self) void {
    const close_rc = linux.close(self.sock_fd);
    switch (errno(close_rc)) {
        .SUCCESS => {},
        .INTR, .IO => |e| std.debug.print("closing client fd: {t}", .{e}),
        else => |e| syscall.errno_bug("close", e),
    }
    self.sock_fd = -1;
}

fn create_deadline(self: Self, duration: Duration) Clock.Timestamp {
    return self.now().addDuration(.{ .clock = .awake, .raw = duration });
}

fn now(self: Self) Clock.Timestamp {
    return .now(self.io, .awake);
}

fn idle_connection_is_expired(self: Self) bool {
    return self.last_request
        .addDuration(.{ .clock = .awake, .raw = self.idle_timeout })
        .compare(.lt, self.now());
}

const TestServer = struct {
    server: Server,
    w_buf: []u8,
    r_buf: []u8,

    const TestStream = struct {
        stream: Stream,
        r: Stream.Reader,
        w: Stream.Writer,

        fn expect_req(
            self: *TestStream,
            arena: Allocator,
            expected_code: protocol.Op,
            expected_key: []const u8,
            expected_value: []const u8,
            response_code: protocol.ResponseCode,
            response_value: []const u8,
        ) !void {
            return expect_request(
                arena,
                &self.r.interface,
                &self.w.interface,
                expected_code,
                expected_key,
                expected_value,
                response_code,
                response_value,
            );
        }

        fn close(self: *TestStream) void {
            self.stream.close(testing.io);
        }
    };

    fn accept(self: *TestServer) !TestStream {
        const stream = try self.server.accept(testing.io);
        return .{
            .stream = stream,
            .r = stream.reader(testing.io, self.r_buf),
            .w = stream.writer(testing.io, self.w_buf),
        };
    }

    fn deinit(self: *TestServer) void {
        self.server.deinit(testing.io);
    }
};

const TestShared = struct {
    result: anyerror!void,
    event: Io.Event,
    arena_alloc: std.heap.ArenaAllocator,

    fn arena(self: *TestShared) Allocator {
        return self.arena_alloc.allocator();
    }
};

const Tester = struct {
    server: TestServer,
    client: Self,
    thread_handle: Thread,
    addr: Ip4Address,
    addr_buf: [21]u8,
    t: *TestShared,

    fn init_connection(f: anytype) !Tester {
        var new_arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer new_arena.deinit();

        const ip = net.IpAddress{ .ip4 = net.Ip4Address.loopback(0) };

        var srv = try ip.listen(testing.io, .{});
        errdefer srv.deinit(testing.io);

        const tsrv = TestServer{
            .server = srv,
            .w_buf = try new_arena.allocator().alloc(u8, 256),
            .r_buf = try new_arena.allocator().alloc(u8, 256),
        };
        const addr = srv.socket.address.ip4;
        var t = try new_arena.allocator().create(TestShared);
        t.event.reset();
        t.arena_alloc = new_arena;
        const thread_handle = try Thread.spawn(.{}, server_func, .{ tsrv, t, f });

        return .{
            .t = t,
            .server = tsrv,
            .thread_handle = thread_handle,
            .client = undefined,
            .addr = addr,
            .addr_buf = undefined,
        };
    }

    fn deinit(self: *Tester) void {
        self.t.arena_alloc.deinit();
    }

    fn join(self: *Tester) anyerror!void {
        self.thread_handle.join();
        return self.t.result;
    }

    fn str_addr(self: *Tester) ![]u8 {
        var w = Io.Writer.fixed(&self.addr_buf);
        try self.addr.format(&w);
        return self.addr_buf[0..w.end];
    }

    fn arena(self: *Tester) Allocator {
        return self.t.arena_alloc.allocator();
    }

    fn server_func(srv: TestServer, t: *TestShared, f: anytype) void {
        var copy = srv;
        defer copy.deinit();
        t.result = @call(.auto, f, .{ &copy, t });
    }
};

test "client connects" {
    var c: Self = undefined;

    const ip = net.IpAddress{ .ip4 = try net.Ip4Address.parse("127.0.0.1", 0) };

    var cond = Io.Condition.init;
    var mutex = Io.Mutex.init;

    var local_address: ?anyerror!net.IpAddress = null;

    var server_result: anyerror!void = undefined;
    const thread = try std.Thread.spawn(
        .{},
        serverfunc,
        .{ ip, &server_result, &cond, &mutex, &local_address },
    );

    try mutex.lock(testing.io);
    defer mutex.unlock(testing.io);

    const addr = try while (local_address == null) {
        try cond.wait(testing.io, &mutex);
    } else local_address.?;

    var str_addr: [21]u8 = undefined;
    var w = Io.Writer.fixed(&str_addr);
    try addr.ip4.format(&w);

    try c.init(testing.io, str_addr[0..w.end], .{});

    var req: Request = .init(
        .get,
        1,
        Clock.Timestamp.fromNow(testing.io, .{ .clock = .awake, .raw = .fromSeconds(5) }),
    );

    try c.connect(&req);

    c.deinit();
    thread.join();
    try server_result;
}

fn serverfunc(
    ip: net.IpAddress,
    result: *anyerror!void,
    cond: *Io.Condition,
    mutex: *Io.Mutex,
    local_address: *?anyerror!net.IpAddress,
) void {
    result.* = server(ip, cond, mutex, local_address);
}

fn server(
    ip: net.IpAddress,
    cond: *Io.Condition,
    mutex: *Io.Mutex,
    local_address: *?anyerror!net.IpAddress,
) !void {
    var srv = blk: {
        errdefer |e| {
            mutex.lockUncancelable(testing.io);
            local_address.* = e;
            mutex.unlock(testing.io);
            cond.broadcast(testing.io);
        }
        var srv = try ip.listen(testing.io, .{});
        errdefer srv.deinit(testing.io);
        break :blk srv;
    };
    defer srv.deinit(testing.io);

    try mutex.lock(testing.io);
    local_address.* = srv.socket.address;
    mutex.unlock(testing.io);

    cond.broadcast(testing.io);

    const stream = try srv.accept(testing.io);
    stream.close(testing.io);
}

fn expect_request(
    arena: Allocator,
    r: *Reader,
    w: *Writer,
    expected_code: protocol.Op,
    expected_key: []const u8,
    expected_value: []const u8,
    response_code: protocol.ResponseCode,
    response_value: []const u8,
) !void {
    const exp = try protocol.encode.encode_client_msg_alloc(
        expected_code,
        expected_key,
        expected_value,
        arena,
    );
    const req: []u8 = try arena.alloc(u8, exp.len);
    try r.readSliceAll(req);
    try testing.expectEqualSlices(u8, exp, req);
    const resp = try protocol.encode.encode_srv_msg(arena, response_code, response_value);
    try w.writeAll(resp);
    try w.flush();
}

test "send request receive response" {
    var t = try Tester.init_connection(send_request_receive_response_server);
    defer t.deinit();
    const addr = try t.str_addr();
    try t.client.init(testing.io, addr, .{});
    defer t.client.deinit();
    var resp = try t.client.set("hola", "chao");
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(protocol.ResponseCode.Ok, resp.code);
    try testing.expectEqual(0, resp.value.len);
    try t.join();
}

fn send_request_receive_response_server(srv: *TestServer, t: *TestShared) !void {
    var s = try srv.accept();
    try s.expect_req(t.arena(), .set, "hola", "chao", .Ok, &.{});
    s.close();
}

test "multiple requests" {
    var t = try Tester.init_connection(multiple_requests_server);
    defer t.deinit();
    const addr = try t.str_addr();
    try t.client.init(testing.io, addr, .{});
    defer t.client.deinit();
    var resp1 = try t.client.del("something else gigantic");
    try testing.expectEqual(protocol.ResponseCode.Ok, resp1.code);
    var resp2 = try t.client.get(t.arena(), "0");
    try testing.expectEqual(protocol.ResponseCode.NotFound, resp2.code);
    try t.join();
}

fn multiple_requests_server(srv: *TestServer, t: *TestShared) !void {
    var s = try srv.accept();
    try s.expect_req(t.arena(), .del, "something else gigantic", &.{}, .Ok, &.{});
    try s.expect_req(t.arena(), .get, "0", &.{}, .NotFound, &.{});
    s.close();
}

test "client reconnects on stale connection" {
    var t = try Tester.init_connection(client_reconnects_on_stale_connection_server);
    defer t.deinit();
    const addr = try t.str_addr();
    try t.client.init(testing.io, addr, .{});
    defer t.client.deinit();

    var resp1 = try t.client.set("something", &.{});
    try testing.expectEqual(protocol.ResponseCode.Ok, resp1.code);

    try t.t.event.waitTimeout(
        testing.io,
        .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(1) } },
    );

    var resp2 = try t.client.get(t.arena(), "0");
    try testing.expectEqual(protocol.ResponseCode.NotFound, resp2.code);

    try t.join();
}

fn client_reconnects_on_stale_connection_server(srv: *TestServer, t: *TestShared) !void {
    var s = try srv.accept();
    try s.expect_req(t.arena(), .set, "something", &.{}, .Ok, "");

    s.close();
    t.event.set(testing.io);

    s = try srv.accept();
    try s.expect_req(t.arena(), .get, "0", &.{}, .NotFound, "");
}

test "reattempts connect" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var str_w = Writer.Allocating.init(arena.allocator());
    defer str_w.deinit();

    const ip: IpAddress = .{ .ip4 = .loopback(0) };

    var srv_sock = try ip.bind(testing.io, .{ .mode = .stream });
    try srv_sock.address.format(&str_w.writer);

    var c: Self = undefined;
    try c.init(testing.io, str_w.written(), .{ .max_attempts = 10 });
    defer c.deinit();

    var ev: Io.Event = .unset;
    var h = try testing.io.concurrent(
        client_reattempts_connect_server,
        .{ &srv_sock, &ev },
    );
    defer h.await(testing.io) catch {};

    ev.set(testing.io);
    const r = try c.del("s");
    try testing.expectEqual(protocol.ResponseCode.Ok, r.code);

    try h.await(testing.io);
}

fn client_reattempts_connect_server(
    sock: *net.Socket,
    ev: *Io.Event,
) !void {
    try ev.waitTimeout(
        testing.io,
        .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(500) } },
    );

    testing.io.sleep(.fromMilliseconds(retry_connect_delay.toMilliseconds() * 2), .awake) catch
        unreachable;

    switch (errno(linux.listen(sock.handle, 0))) {
        .SUCCESS => {},
        else => |e| {
            std.debug.print("unexpected listen errno: {t}\n", .{e});
            return error.Unexpected;
        },
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var srv: Server = .{ .socket = sock.* };
    var s = try srv.accept(testing.io);

    var r_buf: [256]u8 = undefined;
    var w_buf: [256]u8 = undefined;
    var r = s.reader(testing.io, &r_buf);
    var w = s.writer(testing.io, &w_buf);

    try expect_request(arena.allocator(), &r.interface, &w.interface, .del, "s", "", .Ok, "");

    s.close(testing.io);
}

test "retries idempotent after half reading response" {
    var t: Tester = try .init_connection(retries_get_server);
    defer t.deinit();

    try t.client.init(testing.io, try t.str_addr(), .{});
    defer t.client.deinit();

    const resp = try t.client.get(t.arena(), "my key");
    try testing.expectEqual(protocol.ResponseCode.Ok, resp.code);
    try t.join();
}

fn retries_get_server(srv: *TestServer, t: *TestShared) !void {
    var s = try srv.accept();
    const exp = try protocol.encode.encode_client_msg_alloc(.get, "my key", "", t.arena());
    const req = try t.arena().alloc(u8, exp.len);
    try s.r.interface.readSliceAll(req);
    try testing.expectEqualSlices(u8, exp, req);

    const resp = try protocol.encode.encode_srv_msg(t.arena(), .Ok, "");
    try s.w.interface.writeAll(resp[0..3]);
    try s.w.interface.flush();
    s.close();

    s = try srv.accept();
    try s.expect_req(t.arena(), .get, "my key", "", .Ok, "");
    s.close();
}

test "failed request cleans up the socket fd" {
    var t: Tester = try .init_connection(failed_request_cleans_up_fd);
    defer t.deinit();

    try t.client.init(testing.io, try t.str_addr(), .{});
    defer t.client.deinit();

    try testing.expectError(error.UnknownOutcome, t.client.del("."));

    try testing.expectEqual(-1, t.client.sock_fd);

    _ = try t.client.set("set", "hola");

    try t.join();
}

fn failed_request_cleans_up_fd(srv: *TestServer, t: *TestShared) !void {
    var s = try srv.accept();
    _ = try s.r.interface.readAlloc(t.arena(), 10);
    try s.w.interface.writeByte('0');
    try s.w.interface.flush();

    s.close();

    s = try srv.accept();
    try s.expect_req(t.arena(), .set, "set", "hola", .Ok, "");
    s.close();
}

test "unknown outcome if rst after write" {
    var t: Tester = try .init_connection(unknown_outcome_error_rst_after_write_server);
    defer t.deinit();

    try t.client.init(testing.io, try t.str_addr(), .{});
    defer t.client.deinit();

    try testing.expectError(error.UnknownOutcome, t.client.set(&.{ 255, 0 }, &.{ 255, 0 }));
    try t.join();
}

fn unknown_outcome_error_rst_after_write_server(srv: *TestServer, t: *TestShared) !void {
    var s = try srv.accept();

    const expected = try protocol.encode.encode_client_msg_alloc(
        .set,
        &.{ 255, 0 },
        &.{ 255, 0 },
        t.arena(),
    );
    const actual = try s.r.interface.readAlloc(t.arena(), expected.len);
    try testing.expectEqualSlices(u8, expected, actual);

    const linger: linux.linger = .{ .linger = 0, .onoff = 1 };
    const sso_rc = linux.setsockopt(
        s.stream.socket.handle,
        linux.SOL.SOCKET,
        linux.SO.LINGER,
        @ptrCast(&linger),
        @sizeOf(linux.linger),
    );
    switch (errno(sso_rc)) {
        .SUCCESS => {},
        else => return testing.expect(false),
    }

    s.close();
}

test "unknown outcome if fin after write" {
    var t: Tester = try .init_connection(unknown_outcome_error_fin_after_write_server);
    defer t.deinit();

    try t.client.init(testing.io, try t.str_addr(), .{});
    defer t.client.deinit();

    try testing.expectError(error.UnknownOutcome, t.client.set(&.{ 255, 0 }, &.{ 255, 0 }));
    try t.join();
}

fn unknown_outcome_error_fin_after_write_server(srv: *TestServer, t: *TestShared) !void {
    var s = try srv.accept();

    const expected = try protocol.encode.encode_client_msg_alloc(
        .set,
        &.{ 255, 0 },
        &.{ 255, 0 },
        t.arena(),
    );
    const actual = try s.r.interface.readAlloc(t.arena(), expected.len);
    try testing.expectEqualSlices(u8, expected, actual);

    s.close();
}
