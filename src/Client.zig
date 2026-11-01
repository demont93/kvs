const std = @import("std");
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
const Writer = Io.Writer;
const Reader = Io.Reader;

const protocol = @import("protocol.zig");
const syscall = @import("syscall.zig");

const Self = @This();

const max_attempts: i32 = 3;

io: Io,
allocator: Allocator,
addr: linux.sockaddr.in,
sock_fd: i32,
read_timeout: Duration,
write_timeout: Duration,
idle_timeout: Duration,
unexpected: linux.E,

pub const Response = struct {
    code: protocol.ResponseCode,
    value: []u8,

    pub fn deinit(self: *Response, allocator: Allocator) void {
        if (self.value.len > 0) {
            allocator.free(self.value);
        }
    }
};

const RequestState = struct {
    const ConnAge = enum {
        no_connection,
        old_connection,
        new_connection,
    };
    const ConnStatus = union(enum) {
        ready,
        closed,
        unusable: RequestError,
        fatal: RequestError,
        conn_failed: RequestError,
    };
    const Action = enum {
        connect,
        reconnect,
        wait_connect,
        cont,
    };

    conn_age: ConnAge,
    conn_status: ConnStatus,
    attempts: i32,

    fn init(fd: i32) RequestState {
        return .{
            .conn_age = if (fd < 0) .no_connection else .old_connection,
            .conn_status = .ready,
            .attempts = 0,
        };
    }

    fn next(self: *RequestState) ?Action {
        if (self.attempts > max_attempts) {
            return null;
        }

        self.attempts += 1;

        return switch (self.conn_age) {
            .no_connection => blk: {
                if (self.conn_status != .ready) unreachable;
                self.conn_age = .new_connection;
                break :blk .connect;
            },
            .old_connection => switch (self.conn_status) {
                .ready => .cont,
                .unusable, .closed => blk: {
                    self.conn_age = .new_connection;
                    break :blk .reconnect;
                },
                .fatal => null,
                .conn_failed => unreachable,
            },
            .new_connection => switch (self.conn_status) {
                .ready => .cont,
                .conn_failed => .wait_connect,
                .unusable, .closed, .fatal => null,
            },
        };
    }

    fn set(self: *RequestState, status: ConnStatus) void {
        self.conn_status = status;
    }

    fn err(self: RequestState) RequestError {
        return switch (self.conn_status) {
            .closed, .ready => unreachable,
            .fatal, .conn_failed, .unusable => |e| e,
        };
    }
};

pub fn init(
    self: *Self,
    io: Io,
    addr: []const u8,
) error{InvalidAddress}!void {
    self.io = io;
    self.addr = syscall.parse_addr(addr) orelse return error.InvalidAddress;
    self.sock_fd = -1;
    self.write_timeout = .fromSeconds(6);
    self.read_timeout = .fromSeconds(6);
    self.idle_timeout = .fromSeconds(10);
}

pub const ConnectError = error{
    AlreadyConnected,
    PermissionDenied,
    TooManyOpenFiles,
    OutOfMemory,
    InvalidAddress,
    ConnectionRefused,
    NoAddressAvailable,
    Unreachable,
    NetworkTimeout,
    Timeout,
    Unexpected,
};

pub fn get(self: *Self, allocator: Allocator, key: []const u8) !Response {
    if (key.len > protocol.max_key_size) {
        return error.KeyTooLarge;
    }
    var frame: [9]u8 = undefined;
    var bufs: [3][]const u8 = undefined;
    protocol.encode.encode_client_msg(.get, &frame, key, &.{}, &bufs);
    return self.do_request(allocator, .get, &bufs);
}

pub fn set(self: *Self, key: []const u8, value: []const u8) !Response {
    if (key.len > protocol.max_key_size) {
        return error.KeyTooLarge;
    }
    if (value.len > protocol.max_value_size) {
        return error.ValueTooLarge;
    }
    var frame: [9]u8 = undefined;
    var bufs: [3][]const u8 = undefined;
    protocol.encode.encode_client_msg(.set, &frame, key, value, &bufs);
    return self.do_request(null, .set, &bufs);
}

pub fn del(self: *Self, key: []const u8) !Response {
    if (key.len > protocol.max_key_size) {
        return error.KeyTooLarge;
    }
    var frame: [9]u8 = undefined;
    var bufs: [3][]const u8 = undefined;
    protocol.encode.encode_client_msg(.del, &frame, key, &.{}, &bufs);
    return self.do_request(null, .del, &bufs);
}

const RequestError = error{
    PermissionDenied,
    TooManyOpenFiles,
    OutOfMemory,
    ConnectionRefused,
    NoAddressAvailable,
    Unreachable,
    NetworkTimeout,
    Unexpected,
    ConnectionReset,
    UnexpectedBytes,
    WriteTimeout,
    ReadTimeout,
    InvalidAddress,
    UnexpectedEof,
    BadResponse,
};

pub fn do_request(
    self: *Self,
    allocator: ?Allocator,
    op: protocol.Op,
    data: *[3][]const u8,
) !Response {
    var request_state: RequestState = .init(self.sock_fd);

    if (request_state.conn_age == .old_connection) {
        if (self.check_connection()) |state| {
            switch (state) {
                .up => request_state.set(.ready),
                .down => request_state.set(.closed),
            }
        } else |err| {
            switch (err) {
                error.ConnectionReset,
                error.UnexpectedBytes,
                error.Unexpected,
                error.OutOfMemory,
                => |e| request_state.set(.{ .unusable = e }),
            }
        }
    }

    const write_deadline = self.create_deadline(self.write_timeout);

    const result = while (request_state.next()) |action| {
        const connect_result = switch (action) {
            .cont => {},
            .connect => self.connect(write_deadline),
            .reconnect => self.reconnect(write_deadline),
            .wait_connect => blk: {
                self.io.sleep(.fromMilliseconds(100), .awake) catch unreachable;
                break :blk self.connect(write_deadline);
            },
        };

        connect_result catch |err| {
            switch (err) {
                error.AlreadyConnected => unreachable,

                error.PermissionDenied,
                error.TooManyOpenFiles,
                error.OutOfMemory,
                error.ConnectionRefused,
                error.NoAddressAvailable,
                error.Unreachable,
                error.NetworkTimeout,
                error.Unexpected,
                => |e| request_state.set(.{ .conn_failed = e }),

                error.Timeout => request_state.set(.{ .fatal = error.WriteTimeout }),

                error.InvalidAddress => |e| request_state.set(.{ .fatal = e }),
            }
            continue;
        };

        self.writev_all(data, write_deadline) catch |err| {
            switch (err) {
                error.WriteTimeout => |e| request_state.set(.{ .fatal = e }),

                error.Pipe => request_state.set(.closed),

                error.OutOfMemory,
                error.Unexpected,
                error.ConnectionReset,
                => |e| request_state.set(.{ .unusable = e }),

                error.Badf,
                error.NotConnected,
                error.NotSock,
                => syscall.zerrno_bug("write", err),
            }
            continue;
        };

        break self.do_request_read_response(allocator, op) catch |err| {
            switch (err) {
                error.ConnectionWasClosed => request_state.set(.closed),

                error.ReadTimeout,
                error.OutOfMemory,
                error.Unexpected,
                error.ConnectionReset,
                error.UnexpectedEof,
                error.BadResponse,
                => |e| request_state.set(.{ .fatal = e }),
            }
            continue;
        };
    } else request_state.err();

    _ = result catch |err| {
        if (err == error.Unexpected) {
            std.debug.print("unexpected syscall error: {t}\n", .{self.unexpected});
        }
    };

    return result;
}

fn connect(self: *Self, deadline: Clock.Timestamp) ConnectError!void {
    if (self.sock_fd >= 0) {
        return ConnectError.AlreadyConnected;
    }

    const socket_rc = syscall.socket(.NonBlocking);
    switch (errno(socket_rc)) {
        .SUCCESS => {},
        .ACCES => return ConnectError.PermissionDenied,
        .NFILE, .MFILE => return ConnectError.TooManyOpenFiles,
        .NOBUFS, .NOMEM => return ConnectError.OutOfMemory,
        .INVAL, .PROTONOSUPPORT => |e| syscall.errno_bug("socket", e),
        else => |e| return syscall.record_unexpected_errno(&self.unexpected, e),
    }
    self.sock_fd = @intCast(socket_rc);

    errdefer self.close_fd();
    const connect_rc = linux.connect(self.sock_fd, &self.addr, @sizeOf(@TypeOf(self.addr)));
    switch (errno(connect_rc)) {
        .SUCCESS => return,
        .INTR, .INPROGRESS => {},
        .PERM, .ACCES => return ConnectError.PermissionDenied,
        .ADDRNOTAVAIL => return ConnectError.NoAddressAvailable,
        .CONNREFUSED => return ConnectError.ConnectionRefused,
        .NETUNREACH => return ConnectError.Unreachable,
        .TIMEDOUT => return ConnectError.NetworkTimeout,
        .ADDRINUSE,
        .AFNOSUPPORT,
        .AGAIN,
        .ALREADY,
        .BADF,
        .FAULT,
        .ISCONN,
        .NOTSOCK,
        .PROTOTYPE,
        => |e| syscall.errno_bug("connect", e),
        else => |e| return syscall.record_unexpected_errno(&self.unexpected, e),
    }

    var pollfds = [_]linux.pollfd{syscall.pollfd(self.sock_fd, linux.POLL.OUT)};
    _ = syscall.poll(self.io, &pollfds, deadline, &self.unexpected) catch |e| return switch (e) {
        error.TooManyPollFds => syscall.zerrno_bug("poll", e),
        else => |e2| e2,
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
        .PERM, .ACCES => return ConnectError.PermissionDenied,
        .ADDRNOTAVAIL => return ConnectError.NoAddressAvailable,
        .CONNREFUSED => return ConnectError.ConnectionRefused,
        .NETUNREACH => return ConnectError.Unreachable,
        .TIMEDOUT => return ConnectError.NetworkTimeout,
        .ADDRINUSE,
        .AFNOSUPPORT,
        .AGAIN,
        .ALREADY,
        .BADF,
        .FAULT,
        .ISCONN,
        .NOTSOCK,
        .PROTOTYPE,
        => |e| syscall.errno_bug("connect", e),
        else => |e| return syscall.record_unexpected_errno(&self.unexpected, e),
    }
}

fn writev_all(self: *Self, data: *[3][]const u8, deadline: Clock.Timestamp) !void {
    var fds = syscall.pollfd(self.sock_fd, linux.POLL.OUT);

    var iovecs: [3]posix.iovec_const = undefined;
    var full_len: usize = 0;
    var iovecs_len: usize = 0;
    for (data) |*s| {
        if (s.len == 0) continue;
        iovecs[iovecs_len].base = s.ptr;
        iovecs[iovecs_len].len = s.len;
        full_len += s.len;
        iovecs_len += 1;
    }
    var offset: i64 = 0;

    while (true) {
        if (self.now().compare(.gte, deadline)) {
            return error.WriteTimeout;
        }
        var writev_rc = linux.writev(self.sock_fd, &iovecs, iovecs_len);
        switch (errno(writev_rc)) {
            .SUCCESS => offset += @intCast(writev_rc),
            .AGAIN => {},
            .INTR => continue,
            .BADF => return error.Badf,
            .CONNRESET => return error.ConnectionReset,
            .NOMEM => return error.OutOfMemory,
            .NOTCONN => return error.NotConnected,
            .NOTSOCK => return error.NotSock,
            .PIPE => return error.Pipe,
            .ACCES,
            .ALREADY,
            .INVAL,
            .DESTADDRREQ,
            .ISCONN,
            .MSGSIZE,
            .OPNOTSUPP,
            .FAULT,
            => |e| syscall.errno_bug("writev", e),
            else => |e| return syscall.record_unexpected_errno(&self.unexpected, e),
        }
        if (offset >= full_len) {
            return;
        }

        for (&iovecs) |*v| {
            if (writev_rc == 0) break;
            if (v.len == 0) continue;
            const min = @min(v.len, writev_rc);
            v.len -= min;
            v.base += min;
            writev_rc -= min;
        }
        _ = syscall.poll(
            self.io,
            @as(*[1]linux.pollfd, &fds),
            deadline,
            &self.unexpected,
        ) catch |err| return switch (err) {
            error.Timeout => error.WriteTimeout,
            error.Unexpected, error.OutOfMemory => |e| e,
            error.TooManyPollFds => |e| syscall.zerrno_bug("poll", e),
        };
    }
}

const ReadResponseError = error{
    ConnectionWasClosed,
    ReadTimeout,
    UnexpectedEof,
    BadResponse,
    OutOfMemory,
    ConnectionReset,
    Unexpected,
};

fn do_request_read_response(
    self: *Self,
    allocator: ?Allocator,
    op: protocol.Op,
) ReadResponseError!Response {
    const deadline = Clock.Timestamp.fromNow(
        self.io,
        .{ .clock = .awake, .raw = self.read_timeout },
    );

    var frame: [5]u8 = undefined;

    const n_read = self.first_read(&frame, deadline) catch |e|
        return switch (e) {
            error.Eof => error.ConnectionWasClosed,
            else => |e2| e2,
        };

    if (n_read < frame.len) {
        syscall.recv_all(
            self.sock_fd,
            frame[n_read..],
            deadline,
            self.io,
            null,
            &self.unexpected,
        ) catch |e| return switch (e) {
            error.Timeout => error.ReadTimeout,
            error.Badf => syscall.zerrno_bug("read", e),
            error.ConnectionRefused => syscall.record_unexpected_errno(
                &self.unexpected,
                linux.E.CONNREFUSED,
            ),
            else => |e2| e2,
        };
    }

    var response: Response = undefined;

    if (std.enums.fromInt(protocol.ResponseCode, frame[0])) |res| {
        response.code = res;
    } else {
        return error.BadResponse;
    }

    const len = std.mem.readInt(u32, frame[1..], .big);

    if (len > 0 and op != .get) {
        return error.BadResponse;
    }

    if (len > protocol.max_value_size) {
        return error.BadResponse;
    }

    if (len > 0) {
        response.value = try allocator.?.alloc(u8, len);
        errdefer allocator.?.free(response.value);

        syscall.recv_all(
            self.sock_fd,
            response.value,
            deadline,
            self.io,
            null,
            &self.unexpected,
        ) catch |e| return switch (e) {
            error.Timeout => error.ReadTimeout,
            error.Badf => syscall.zerrno_bug("read", e),
            error.ConnectionRefused => syscall.record_unexpected_errno(
                &self.unexpected,
                linux.E.CONNREFUSED,
            ),
            else => |e2| e2,
        };
    } else {
        response.value = &[_]u8{};
    }
    return response;
}

fn first_read(self: *Self, frame: []u8, deadline: Clock.Timestamp) !usize {
    if (Clock.Timestamp.now(self.io, .awake).compare(.gte, deadline)) {
        return error.ReadTimeout;
    }
    var i = syscall.recv(self.sock_fd, frame, &self.unexpected) catch |e| switch (e) {
        error.Again => 0,
        error.OutOfMemory, error.Eof, error.Unexpected, error.ConnectionReset => |e2| return e2,
        error.ConnectionRefused, error.Badf => syscall.zerrno_bug("read", e),
    };

    while (i == 0) {
        var fds = syscall.pollfd(self.sock_fd, linux.POLL.IN);
        _ = syscall.poll(
            self.io,
            @as(*[1]linux.pollfd, &fds),
            deadline,
            &self.unexpected,
        ) catch |e| return switch (e) {
            error.TooManyPollFds => unreachable,
            error.Timeout => error.ReadTimeout,
            error.OutOfMemory, error.Unexpected => |e2| e2,
        };

        i += syscall.recv(self.sock_fd, frame, &self.unexpected) catch |e| switch (e) {
            error.Again => 0,
            error.OutOfMemory,
            error.Eof,
            error.Unexpected,
            error.ConnectionReset,
            => |e2| return e2,
            error.ConnectionRefused, error.Badf => syscall.zerrno_bug("read", e),
        };
    }

    return i;
}

fn check_connection(self: *Self) !enum { up, down } {
    var buf: [1]u8 = undefined;
    const recv_rc = linux.recvfrom(self.sock_fd, &buf, buf.len, linux.MSG.PEEK, null, null);
    while (true) {
        return switch (errno(recv_rc)) {
            .AGAIN => .up,
            .SUCCESS => if (recv_rc == 0) .down else error.UnexpectedBytes,
            .INTR => continue,
            .CONNRESET => error.ConnectionReset,
            .NOMEM => error.OutOfMemory,
            .BADF, .CONNREFUSED, .FAULT, .INVAL, .NOTCONN => |e| syscall.errno_bug("recvfrom", e),
            else => |e| syscall.record_unexpected_errno(&self.unexpected, e),
        };
    }
}

pub fn deinit(self: *Self) void {
    if (self.sock_fd < 0) {
        return;
    }

    self.close_fd();
}

fn reconnect(self: *Self, deadline: Clock.Timestamp) ConnectError!void {
    self.close_fd();
    try self.connect(deadline);
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

    fn accept(self: *TestServer) !struct { Stream, Stream.Reader, Stream.Writer } {
        const stream = try self.server.accept(testing.io);
        return .{
            stream,
            stream.reader(testing.io, self.r_buf),
            stream.writer(testing.io, self.w_buf),
        };
    }

    fn accept2(self: *TestServer) !TestStream {
        const stream = try self.server.accept(testing.io);
        return .{
            .stream = stream,
            .r = stream.reader(testing.io, self.r_buf),
            .w = stream.writer(testing.io, self.w_buf),
        };
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
        const srv = try ip.listen(testing.io, .{});
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

    try c.init(testing.io, str_addr[0..w.end]);

    try c.connect(.fromNow(testing.io, .{ .raw = .fromMilliseconds(200), .clock = .awake }));

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
    try t.client.init(testing.io, addr);
    var resp = try t.client.set("hola", "chao");
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(protocol.ResponseCode.Ok, resp.code);
    try testing.expectEqual(0, resp.value.len);
    try t.join();
}

fn send_request_receive_response_server(srv: *TestServer, t: *TestShared) !void {
    var s = try srv.accept2();
    try s.expect_req(t.arena(), .set, "hola", "chao", .Ok, &.{});
    s.close();
}

test "multiple requests" {
    var t = try Tester.init_connection(multiple_requests_server);
    defer t.deinit();
    const addr = try t.str_addr();
    try t.client.init(testing.io, addr);
    var resp1 = try t.client.del("something else gigantic");
    try testing.expectEqual(protocol.ResponseCode.Ok, resp1.code);
    var resp2 = try t.client.get(t.arena(), "0");
    try testing.expectEqual(protocol.ResponseCode.NotFound, resp2.code);
    try t.join();
}

fn multiple_requests_server(srv: *TestServer, t: *TestShared) !void {
    var s = try srv.accept2();
    try s.expect_req(t.arena(), .del, "something else gigantic", &.{}, .Ok, &.{});
    try s.expect_req(t.arena(), .get, "0", &.{}, .NotFound, &.{});
    s.close();
}

test "client reconnects on stale connection" {
    var t = try Tester.init_connection(client_reconnects_on_stale_connection_server);
    defer t.deinit();
    const addr = try t.str_addr();
    try t.client.init(testing.io, addr);

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
    var s = try srv.accept2();
    try s.expect_req(t.arena(), .set, "something", &.{}, .Ok, "");

    s.close();
    t.event.set(testing.io);

    s = try srv.accept2();
    try s.expect_req(t.arena(), .get, "0", &.{}, .NotFound, "");
}
