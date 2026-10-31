const std = @import("std");
const debug = std.debug;
const Io = std.Io;
const linux = std.os.linux;
const math = std.math;
const os = std.os;
const testing = std.testing;
const Thread = std.Thread;
const net = Io.net;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const builtin = @import("builtin");
const assert = debug.assert;
const Clock = Io.Clock.awake;
const BufMap = std.BufMap;
const encode = protocol.encode;
const syscall = @import("syscall.zig");

const protocol = @import("protocol.zig");

const Self = @This();

pub const Listener = struct {
    /// Expected to be initialized in non-blocking mode.
    pub const Connection = struct {
        sock_fd: i32 = -1,

        pub const RwError = error{
            ConnectionReset,
            WouldBlock,
            Unexpected,
        };

        pub fn read(self: *Connection, buf: []u8, unexpected: *linux.E) RwError!usize {
            return while (true) {
                const read_rc = linux.read(self.sock_fd, buf.ptr, buf.len);
                switch (linux.errno(read_rc)) {
                    .SUCCESS => break read_rc,
                    .INTR => continue,
                    .CONNRESET, .PIPE => return RwError.ConnectionReset,
                    .AGAIN => return RwError.WouldBlock,
                    .BADF,
                    .FAULT,
                    .NOTSOCK,
                    .INVAL,
                    .NOTCONN,
                    => |e| syscall.errno_bug("read", e),
                    else => |e| return syscall.record_unexpected_errno(unexpected, e),
                }
            };
        }

        pub fn write(self: *Connection, buf: []const u8, unexpected: *linux.E) RwError!usize {
            return while (true) {
                const write_rc = linux.write(self.sock_fd, buf.ptr, buf.len);
                switch (linux.errno(write_rc)) {
                    .SUCCESS => break write_rc,
                    .INTR => continue,
                    .CONNRESET, .PIPE => return RwError.ConnectionReset,
                    .AGAIN => return RwError.WouldBlock,
                    .BADF,
                    .FAULT,
                    .NOTSOCK,
                    .INVAL,
                    .NOTCONN,
                    => |e| syscall.errno_bug("write", e),
                    else => |e| return syscall.record_unexpected_errno(unexpected, e),
                }
            };
        }

        const ReadExactError = error{UnexpectedEof} || RwError;

        pub fn shutdown(self: *Connection) void {
            const shut_rc = linux.shutdown(self.sock_fd, linux.SHUT.WR);
            switch (linux.errno(shut_rc)) {
                .SUCCESS, .NOTCONN => {},
                else => |e| syscall.errno_bug("shutdown", e),
            }
        }

        pub fn close(self: *Connection) void {
            const rc = linux.close(self.sock_fd);
            switch (linux.errno(rc)) {
                .SUCCESS, .INTR => {},
                .BADF => |e| syscall.errno_bug("close", e),
                else => |e| log_err("closing connection", e),
            }
            self.sock_fd = -1;
            return;
        }
    };

    sock_fd: i32 = -1,
    backlog: u32 = 511,

    const BindError = error{
        PermissionDenied,
        TooManyOpenFiles,
        InsufficientMemory,
        InvalidAddress,
        AddressInUse,
    };

    fn bind(self: *Listener, addr: []const u8) BindError!void {
        const socket_rc = syscall.socket(.Blocking);
        switch (linux.errno(socket_rc)) {
            .SUCCESS => self.sock_fd = @intCast(socket_rc),
            .ACCES => return BindError.PermissionDenied,
            .MFILE, .NFILE => return BindError.TooManyOpenFiles,
            .NOBUFS, .NOMEM => return BindError.InsufficientMemory,
            else => |e| syscall.errno_bug("socket", e),
        }

        const optval: c_int = 1;
        const sso_rc = linux.setsockopt(
            self.sock_fd,
            linux.SOL.SOCKET,
            linux.SO.REUSEADDR,
            @ptrCast(&optval),
            @sizeOf(c_int),
        );
        switch (linux.errno(sso_rc)) {
            .SUCCESS => {},
            else => |e| syscall.errno_bug("setsockopt", e),
        }

        const sock_addr = syscall.parse_addr(addr) orelse return BindError.InvalidAddress;
        const bind_rc = linux.bind(
            self.sock_fd,
            @ptrCast(&sock_addr),
            @sizeOf(@TypeOf(sock_addr)),
        );
        switch (linux.errno(bind_rc)) {
            .SUCCESS => {},
            .ACCES, .ADDRNOTAVAIL, .FAULT => return BindError.InvalidAddress,
            .ADDRINUSE => return BindError.AddressInUse,
            .NOMEM => return BindError.InsufficientMemory,
            else => |e| syscall.errno_bug("bind", e),
        }

        const listen_rc = linux.listen(self.sock_fd, self.backlog);
        switch (linux.errno(listen_rc)) {
            .SUCCESS => {},
            .ADDRINUSE => return BindError.AddressInUse,
            else => |e| syscall.errno_bug("listen", e),
        }
    }

    pub const AcceptError = error{
        Aborted,
        InsufficientMemory,
        TooManyOpenFiles,
        Firewall,
    };

    pub fn accept(self: *Listener) AcceptError!Connection {
        var peer_addr: linux.sockaddr = undefined;
        var peer_addr_len: linux.socklen_t = @sizeOf(@TypeOf(peer_addr));
        const conn_sock_fd = while (true) {
            const accept_rc = linux.accept4(
                self.sock_fd,
                &peer_addr,
                &peer_addr_len,
                linux.SOCK.NONBLOCK,
            );
            const conn_sock_fd: i32 = switch (linux.errno(accept_rc)) {
                .SUCCESS => @intCast(accept_rc),
                .CONNABORTED => return AcceptError.Aborted,
                .INTR => continue,
                .MFILE, .NFILE => return AcceptError.TooManyOpenFiles,
                .NOBUFS, .NOMEM => return AcceptError.InsufficientMemory,
                .PERM => return AcceptError.Firewall,
                .NETDOWN,
                .NOPROTOOPT,
                .HOSTDOWN,
                .NONET,
                .HOSTUNREACH,
                .NETUNREACH,
                => continue,
                .BADF,
                .FAULT,
                .INVAL,
                .OPNOTSUPP,
                .PROTO,
                .AGAIN,
                => |e| syscall.errno_bug("accept", e),
                else => |e| {
                    log_err("unexpected accept error", e);
                    continue;
                },
            };
            break conn_sock_fd;
        };

        return Connection{ .sock_fd = conn_sock_fd };
    }

    pub fn close(self: *Listener) void {
        if (self.sock_fd != -1) {
            const close_rc = linux.close(self.sock_fd);
            switch (linux.errno(close_rc)) {
                .SUCCESS, .INTR => {},
                .BADF => |e| syscall.errno_bug("close", e),
                else => |e| log_err("closing listener", e),
            }
        }
    }

    pub const AddrError = error{
        InsufficientMemory,
        InvalidAddr,
    };

    pub fn local_addr(self: Listener, addr: *linux.sockaddr, len: *u32) AddrError!void {
        const rc = linux.getsockname(self.sock_fd, addr, len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .FAULT, .INVAL => return AddrError.InvalidAddr,
            .NOBUFS => return AddrError.InsufficientMemory,
            else => |e| syscall.errno_bug("getsockname", e),
        }
    }
};

const BufReader = struct {
    start: usize = 0,
    end: usize = 0,
    buf: []u8,

    inline fn write(self: *BufReader) []u8 {
        self.start = 0;
        self.end = 0;
        return self.buf;
    }

    inline fn mark_written(self: *BufReader, size: usize) void {
        self.end = size;
    }

    /// Consumes given contents.
    fn contents(self: *BufReader, size: usize) []u8 {
        const start = self.start;
        self.start = @min(self.start + size, self.end);
        return self.buf[start..self.start];
    }

    fn reset(self: *BufReader) void {
        self.start = 0;
        self.end = 0;
    }
};

pub const ServerOpts = struct {
    read_timeout: Io.Duration = .fromSeconds(6),
    write_timeout: Io.Duration = .fromSeconds(6),
    idle_timeout: Io.Duration = .fromSeconds(10),
    grace_period: Io.Duration = .fromSeconds(2),
    read_buf_size: usize = 1024 * 4,
    max_drain: usize = 1024 * 4,
};

const Action = enum {
    FirstRead,
    SubsequentReads,
    Parse,
    Write,
    Encode,
    Handler,

    fn description(self: Action) []const u8 {
        return switch (self) {
            .FirstRead => "reading request after idle",
            .SubsequentReads => "reading remaining request",
            .Parse => "parsing request",
            .Write => "writing response",
            .Encode => "encoding response",
            .Handler => "handling request",
        };
    }
};

const ConnectionDiagnostics = struct {
    action: Action,
    details: anyerror,

    fn record(
        self: *ConnectionDiagnostics,
        action: Action,
        details: anyerror,
    ) void {
        self.action = action;
        self.details = details;
    }
};

const RetryState = struct {
    const max_backoff: i32 = 1600;
    const initial_backoff: i32 = 200;

    backoff: i32 = initial_backoff,

    fn wait(self: *RetryState, io: Io) void {
        debug.print("backing off for {}ms\n", .{self.backoff});
        io.sleep(.fromMilliseconds(self.backoff), Clock) catch debug.panic("can't sleep", .{});
        if (self.backoff < max_backoff) self.backoff *= 2;
    }

    fn reset(self: *RetryState) void {
        self.backoff = initial_backoff;
    }
};

io: Io,
listener: Listener,
mem_buf: []align(std.atomic.cache_line) u8,
read_buf: BufReader,
drain_buf: []u8,
read_timeout: Io.Duration,
write_timeout: Io.Duration,
idle_timeout: Io.Duration,
grace_period: Io.Duration,
parser: protocol.Parser,
allocator: Allocator,
retry_state: RetryState,
unexpected_errno: linux.E,

map: BufMap,

pub fn init(self: *Self, allocator: Allocator, io: Io, opts: ServerOpts) error{OutOfMemory}!void {
    self.io = io;
    self.allocator = allocator;

    self.listener = .{};

    self.retry_state = .{};

    // Allocate buffers from one block.
    const mem_size = alloc_size(opts.read_buf_size, opts.max_drain);
    self.mem_buf = try allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.atomic.cache_line),
        mem_size.size,
    );
    self.read_buf = .{ .buf = self.mem_buf[0..mem_size.split] };
    self.drain_buf = self.mem_buf[mem_size.split..];

    self.read_timeout = opts.read_timeout;
    self.write_timeout = opts.write_timeout;
    self.idle_timeout = opts.idle_timeout;
    self.grace_period = opts.grace_period;

    self.parser = .{};

    self.map = BufMap.init(allocator);
}

pub fn listen_and_serve(
    self: *Self,
    addr: []const u8,
) void {
    self.bind(addr) catch |e| {
        debug.print("failed to bind to address {s}: {s}\n", .{ addr, @errorName(e) });
        return;
    };

    var localaddr: linux.sockaddr.in = undefined;
    self.local_addr(&localaddr) catch |e| {
        debug.print("failed to get local address: {s}\n", .{@errorName(e)});
        return;
    };

    debug.print("Listening and serving on {s}\n", .{format_addr(localaddr)});

    var diag: ConnectionDiagnostics = undefined;

    while (true) {
        var conn = if (self.listener.accept()) |conn| blk: {
            self.retry_state.reset();
            break :blk conn;
        } else |err| {
            debug.print("error accepting connection: {s}\n", .{@errorName(err)});
            switch (err) {
                error.InsufficientMemory, error.TooManyOpenFiles => self.retry_state.wait(self.io),
                else => self.retry_state.reset(),
            }
            continue;
        };

        const result = self.handle_connection(&conn, &diag);
        conn.close();
        result catch |e| {
            switch (e) {
                error.Unexpected => log(
                    "connection error: unexpected {t}",
                    .{self.unexpected_errno},
                ),
                else => debug.print(
                    "connection error {t} while {s}\n",
                    .{ diag.details, diag.action.description() },
                ),
            }
        };
    }
}

fn bind(self: *Self, addr: []const u8) Listener.BindError!void {
    return self.listener.bind(addr);
}

fn listen_and_serve_one(
    self: *Self,
    diag: *ConnectionDiagnostics,
) (RequestError || Listener.AcceptError)!void {
    var conn = try self.listener.accept();
    defer conn.close();
    try self.handle_connection(&conn, diag);
}

pub fn close(self: *Self) void {
    self.listener.close();
    self.allocator.free(self.mem_buf);
    self.map.deinit();
}

const RequestError = error{
    ConnectionReset,
    ReadTimeout,
    WriteTimeout,
    OutOfMemory,
    BadRequest,
    Unexpected,
};

fn handle_connection(
    self: *Self,
    conn: *Listener.Connection,
    diag: *ConnectionDiagnostics,
) RequestError!void {
    var result: RequestResult = .Continue;
    defer self.read_buf.reset();
    while (result == .Continue) {
        result = try self.handle_request(conn, diag);
    }
}

const RequestResult = enum {
    Done,
    Continue,
};

fn handle_request(
    self: *Self,
    conn: *Listener.Connection,
    diag: *ConnectionDiagnostics,
) RequestError!RequestResult {
    var req = protocol.Request{};
    defer {
        if (req.buf) |buf| {
            self.allocator.free(buf);
        }
    }

    const read_result = self.read_request(conn, diag, &req) catch |err| {
        const error_response = switch (err) {
            error.ConnectionReset, error.Unexpected => |e| return e,
            error.OutOfMemory => encode.internal,
            error.BadRequest => encode.invalid,
            error.ReadTimeout => encode.timeout,
        };
        self.write_drain(conn, error_response);
        return @errorCast(err);
    };

    switch (read_result) {
        .Done => |r| return r,
        .Continue => {},
    }

    const response, const free = self.handler(&req, diag) catch |e| {
        self.write_drain(conn, protocol.encode.internal);
        return e;
    };
    defer {
        if (free) self.allocator.free(response);
    }

    self.write_all(conn, response) catch |err| {
        diag.record(.Write, err);
        return @errorCast(err);
    };

    return .Continue;
}

fn handler(
    self: *Self,
    req: *protocol.Request,
    diag: *ConnectionDiagnostics,
) !struct { []const u8, bool } {
    switch (req.op) {
        .get => {
            if (self.map.get(req.key())) |v| {
                const msg = encode.value(self.allocator, v) catch |err| {
                    diag.record(.Encode, err);
                    return err;
                };
                return .{ msg, true };
            } else {
                return .{ encode.not_found, false };
            }
        },
        .del => {
            if (self.map.hash_map.fetchRemove(req.key())) |kv| {
                self.map.hash_map.allocator.free(kv.key);
                self.map.hash_map.allocator.free(kv.value);
                return .{ encode.ok, false };
            } else {
                return .{ encode.not_found, false };
            }
        },
        .set => {
            if (self.map.put(req.key(), req.value())) |_| {
                return .{ encode.ok, false };
            } else |e| {
                diag.record(.Handler, e);
                return e;
            }
        },
    }
}

const ReadRequestError = error{
    ConnectionReset,
    OutOfMemory,
    BadRequest,
    ReadTimeout,
    Unexpected,
};

fn read_request(
    self: *Self,
    conn: *Listener.Connection,
    diag: *ConnectionDiagnostics,
    req: *protocol.Request,
) ReadRequestError!RequestResult {
    self.parser.reset();

    // First Read
    var done, const deadline = first_read: {
        const idle_deadline = self.make_deadline(self.idle_timeout);
        var chunk = self.read_buffered(
            conn,
            self.parser.bytes_required(),
            idle_deadline,
        ) catch |e| {
            const err = switch (e) {
                error.ReadTimeout => return .Done,
                else => |err| return err,
            };
            diag.record(.FirstRead, err);
            return err;
        };
        if (chunk.len == 0) {
            return .Done;
        }
        const deadline = self.make_deadline(self.read_timeout);

        const done = self.parser.parse(self.allocator, chunk, req) catch |e|
            return handle_parse_err(e, diag);

        break :first_read .{ done, deadline };
    };

    // Subsequent reads
    while (!done) {
        const needed = self.parser.bytes_required();
        const chunk = self.read_buffered(conn, needed, deadline) catch |e| {
            diag.record(.SubsequentReads, e);
            return e;
        };
        if (chunk.len == 0) {
            diag.record(.SubsequentReads, error.UnexpectedEof);
            return error.BadRequest;
        }
        done = self.parser.parse(self.allocator, chunk, req) catch |e|
            return handle_parse_err(e, diag);
    }

    return .Continue;
}

const ParseError = error{
    OutOfMemory,
    BadRequest,
};

fn handle_parse_err(err: protocol.ParseError, diag: *ConnectionDiagnostics) ParseError {
    const e = switch (err) {
        error.InvalidRequest, error.UnexpectedBytes, error.EmptyRequest => error.BadRequest,
        error.OutOfMemory => |e| e,
        error.RequestBufInitialized => @panic("request buffer started initialized"),
    };
    diag.record(.Parse, err);
    return e;
}

const ReadError = error{
    ReadTimeout,
    OutOfMemory,
    ConnectionReset,
    Unexpected,
};

fn read_buffered(
    self: *Self,
    conn: *Listener.Connection,
    size: usize,
    deadline: Io.Clock.Timestamp,
) ReadError![]u8 {
    var chunk = self.read_buf.contents(size);
    if (chunk.len == 0) {
        var pollfd = syscall.pollfd(conn.sock_fd, linux.POLL.IN);

        var n = conn.read(self.read_buf.write(), &self.unexpected_errno) catch |e| switch (e) {
            error.WouldBlock => 0,
            else => |e| return e,
        };

        if (n == 0) {
            const pollfds: *[1]linux.pollfd = &pollfd;
            _ = syscall.poll(
                self.io,
                pollfds,
                deadline,
                &self.unexpected_errno,
            ) catch |e| return switch (e) {
                error.Timeout => error.ReadTimeout,
                error.TooManyPollFds => syscall.zerrno_bug("poll", e),
                else => |e2| return e2,
            };

            n = conn.read(self.read_buf.write(), &self.unexpected_errno) catch |e| switch (e) {
                error.Unexpected => |err| return err,
                error.WouldBlock => syscall.errno_bug("read", linux.E.AGAIN),
                else => |e| return e,
            };
        }
        self.read_buf.mark_written(n);
        chunk = self.read_buf.contents(size);
    }
    return chunk;
}

fn timeout_remaining_ms(self: Self, deadline: Io.Clock.Timestamp) ?i32 {
    const timeout = deadline.durationFromNow(self.io).raw.toMilliseconds();
    return if (timeout > 0) @intCast(timeout) else null;
}

const WriteError = error{
    WriteTimeout,
    OutOfMemory,
    ConnectionReset,
    Unexpected,
};

/// Shuts down the write side of the connection. Caller must close after calling this.
fn write_drain(self: *Self, conn: *Listener.Connection, buf: []const u8) void {
    self.write_all(conn, buf) catch return;
    conn.shutdown();
    self.drain(conn);
}

fn drain(self: *Self, conn: *Listener.Connection) void {
    const deadline = self.make_deadline(self.grace_period);
    var pollfd = syscall.pollfd(conn.sock_fd, linux.POLL.IN);
    var i: usize = 0;
    while (i < self.drain_buf.len) {
        _ = syscall.poll(
            self.io,
            @as(*[1]linux.pollfd, &pollfd),
            deadline,
            &self.unexpected_errno,
        ) catch |e| switch (e) {
            error.Timeout, error.Unexpected => return,
            error.TooManyPollFds => syscall.zerrno_bug("poll", e),
            error.OutOfMemory => log("OutOfMemory when draining request\n", .{}),
        };

        const n = conn.read(self.drain_buf[i..], &self.unexpected_errno) catch return;
        if (n == 0) return;
        i += n;
    }
}

fn write_all(
    self: *Self,
    conn: *Listener.Connection,
    buf: []const u8,
) WriteError!void {
    const deadline = self.make_deadline(self.write_timeout);
    try self.write_all_poll(conn, buf, deadline);
}

fn write_all_poll(
    self: *Self,
    conn: *Listener.Connection,
    buf: []const u8,
    deadline: Io.Clock.Timestamp,
) WriteError!void {
    syscall.send_all_poll(
        conn.sock_fd,
        buf,
        deadline,
        self.io,
        &self.unexpected_errno,
    ) catch |e| switch (e) {
        error.Timeout => return error.WriteTimeout,
        error.ConnectionReset, error.OutOfMemory, error.Unexpected => |e| return e,
        else => |e| syscall.zerrno_bug("send | poll", e),
    };
}

fn local_addr(self: Self, addr: *linux.sockaddr.in) Listener.AddrError!void {
    var len: u32 = @sizeOf(@TypeOf(addr));
    try self.listener.local_addr(@ptrCast(addr), &len);
}

fn format_addr(localaddr: linux.sockaddr.in) [22:0]u8 {
    var addr_buf: [22:0]u8 = undefined;
    const bytes: *const [4]u8 = @ptrCast(&localaddr.addr);
    const printed = std.fmt.bufPrint(&addr_buf, "{}.{}.{}.{}:{}", .{
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        @byteSwap(localaddr.port),
    }) catch unreachable;
    addr_buf[printed.len] = 0;
    return addr_buf;
}

fn alloc_size(req_read_buf: usize, req_drain_buf: usize) struct { size: usize, split: usize } {
    const cache_line = std.atomic.cache_line;
    const mask: usize = cache_line - 1;
    const read_buf: usize = if (req_read_buf & mask > 0)
        (req_read_buf & ~mask) + cache_line
    else
        req_read_buf & ~mask;
    return .{ .size = read_buf + req_drain_buf, .split = read_buf };
}

/// Expects a non-negative duration. Fails if duration is too long.
fn to_timeval(duration: Io.Duration) ?linux.timeval {
    assert(duration.nanoseconds >= 0);
    const us: i64 = @intCast(@divTrunc(@rem(duration.nanoseconds, 1_000_000_000), 1000));
    const s = math.cast(isize, duration.toSeconds()) orelse return null;
    return .{ .sec = s, .usec = us };
}

fn make_deadline(self: Self, duration: Io.Duration) Io.Clock.Timestamp {
    return Io.Clock.Timestamp.fromNow(
        self.io,
        Io.Clock.Duration{ .raw = duration, .clock = Clock },
    );
}

fn now(self: Self) Io.Clock.Timestamp {
    return Io.Clock.Timestamp.now(self.io, Clock);
}

fn log(comptime fmt: []const u8, args: anytype) void {
    debug.print(fmt, args);
}

fn log_err(msg: []const u8, e: anytype) void {
    debug.print("{s}: {t}\n", .{ msg, e });
}

test {
    testing.refAllDecls(@This());
}

test "bind to a connection and read happy" {
    var t: Tester = undefined;

    try t.init(.{});

    var response_buf: [5]u8 = undefined;
    try t.write_request(
        &[_]u8{ 0, 0, 0, 4, 0, 0, 0, 4, @intFromEnum(protocol.Op.get), 'h', 'o', 'l', 'a' },
        &response_buf,
    );

    try testing.expectEqualSlices(
        u8,
        &[_]u8{ @intFromEnum(protocol.encode.ResponseCode.NotFound), 0, 0, 0, 0 },
        &response_buf,
    );

    t.close() catch |e| {
        debug.print("error {} while {s}\n", .{ t.diag.details, t.diag.action.description() });
        return e;
    };
}

test "slow writing client gets read timeout" {
    var t: Tester = undefined;
    try t.init(.{ .read_timeout = .fromMilliseconds(400) });
    var w = t.client_writer();
    const n_written = try w.interface.write(&[_]u8{0});
    try testing.expectEqual(1, n_written);
    try w.interface.flush();
    var response: [5]u8 = undefined;
    var r = t.client_reader();
    try r.interface.readSliceAll(&response);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ @intFromEnum(protocol.encode.ResponseCode.Timeout), 0, 0, 0, 0 },
        &response,
    );
    try testing.expectError(error.ReadTimeout, t.close());
    try testing.expectEqual(Action.SubsequentReads, t.diag.action);
    try testing.expectEqual(error.ReadTimeout, t.diag.details);
}

test "slow reading client gets write timeout" {
    var t: Tester = undefined;
    try t.init(.{ .write_timeout = .fromMilliseconds(400) });
    const value = try testing.allocator.alloc(u8, 15 * 1024 * 1024);
    defer testing.allocator.free(value);
    try t.server.map.put("ale", value);
    var w = t.client_writer();
    try w.interface.writeAll(
        &[_]u8{ 0, 0, 0, 3, 0, 0, 0, 3, 0, 'a', 'l', 'e' },
    );
    try w.interface.flush();
    var response: [20]u8 = undefined;
    var r = t.client_reader();
    try r.interface.readSliceAll(&response);
    try testing.io.sleep(.fromMilliseconds(400), .awake);
    try testing.expectError(error.WriteTimeout, t.close());
    try testing.expectEqual(Action.Write, t.diag.action);
    try testing.expectEqual(error.WriteTimeout, t.diag.details);
}

test "large invalid request gets rst" {
    var t: Tester = undefined;
    try t.init(.{});
    var w = t.client_writer();
    const large = try testing.allocator.alloc(u8, 18 * 1024 * 1024);
    defer testing.allocator.free(large);
    @memset(large, 128);
    try testing.expectError(error.WriteFailed, w.interface.writeAll(large));
    try testing.expectEqual(error.SocketUnconnected, w.err.?);
    try testing.expectError(error.BadRequest, t.close());
    try testing.expectEqual(Action.Parse, t.diag.action);
    try testing.expectEqual(error.InvalidRequest, t.diag.details);
}

test "a small invalid request closes gracefully" {
    var t: Tester = undefined;
    try t.init(.{ .max_drain = 2048 });
    const small_invalid = try testing.allocator.alloc(u8, 2000);
    defer testing.allocator.free(small_invalid);
    var w = t.client_writer();
    try w.interface.writeAll(small_invalid);
    try w.interface.flush();
    var buf: [5]u8 = undefined;
    var r = t.client_reader();
    try r.interface.readSliceAll(&buf);
    var eofbuf: [1]u8 = undefined;
    try testing.expectError(error.EndOfStream, r.interface.readSliceAll(&eofbuf));
    try testing.expectError(error.BadRequest, t.close());
    try testing.expectEqual(Action.Parse, t.diag.action);
    try testing.expectEqual(error.InvalidRequest, t.diag.details);
}

test "many requests on the same connection" {
    var t: Tester = undefined;
    try t.init(.{});
    var set = [_]u8{ 0, 0, 0, 6, 0, 0, 0, 3, 1, 1, 2, 3, 4, 5, 6 };
    var get = [_]u8{ 0, 0, 0, 3, 0, 0, 0, 3, 0, 1, 2, 3 };
    var del = [_]u8{ 0, 0, 0, 3, 0, 0, 0, 3, 2, 1, 2, 3 };

    var w = t.client_writer();
    var r = t.client_reader();

    var resp1: [5]u8 = undefined;
    try w.interface.writeAll(&set);
    try w.interface.flush();
    try r.interface.readSliceAll(&resp1);
    try testing.expectEqualSlices(u8, protocol.encode.ok, &resp1);

    var resp2: [8]u8 = undefined;
    try w.interface.writeAll(&get);
    try w.interface.flush();
    try r.interface.readSliceAll(&resp2);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 3, 4, 5, 6 }, &resp2);

    var resp3: [5]u8 = undefined;
    try w.interface.writeAll(&del);
    try w.interface.flush();
    try r.interface.readSliceAll(&resp3);
    try testing.expectEqualSlices(u8, protocol.encode.ok, &resp3);

    var resp4: [5]u8 = undefined;
    try w.interface.writeAll(&get);
    try w.interface.flush();
    try r.interface.readSliceAll(&resp4);
    try testing.expectEqualSlices(u8, protocol.encode.not_found, &resp4);

    try t.close();
}

test "idle connection timeout" {
    var t: Tester = undefined;
    try t.init(.{ .idle_timeout = .fromMilliseconds(200), .grace_period = .fromMilliseconds(50) });
    var w = t.client_writer();
    var r = t.client_reader();
    var buf: [5]u8 = undefined;

    try w.interface.writeAll(&[_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 0, 1 });
    try w.interface.flush();
    try r.interface.readSliceAll(&buf);
    try testing.expectEqualSlices(u8, protocol.encode.not_found, &buf);

    try testing.io.sleep(.fromMilliseconds(180), .awake);

    try w.interface.writeAll(&[_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 0, 1 });
    try w.interface.flush();
    try r.interface.readSliceAll(&buf);
    try testing.expectEqualSlices(u8, protocol.encode.not_found, &buf);

    try testing.io.sleep(.fromMilliseconds(300), .awake);

    try w.interface.writeAll(&[_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 0, 1 });
    try w.interface.flush();
    _ = try w.interface.write(&[_]u8{0});
    try testing.expectError(error.WriteFailed, w.interface.flush());
    try testing.expectEqual(error.SocketUnconnected, w.err.?);

    try t.close();
}

test "data doesn't leak into next connection" {
    var t: Tester = undefined;
    try t.init(.{});

    var w = t.client_writer();
    var r = t.client_reader();

    try w.interface.writeAll(
        &[_]u8{ 0, 0, 0, 6, 0, 0, 0, 3, 1, 1, 2, 3, 4, 5, 6, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 },
    );
    try w.interface.flush();

    var buf: [5]u8 = undefined;
    try r.interface.readSliceAll(&buf);
    try testing.expectEqualSlices(u8, protocol.encode.ok, &buf);
    const result = t.close_connection();
    errdefer debug.print("\n{any}\n", .{result});

    try t.new_connection();

    w = t.client_writer();
    r = t.client_reader();

    try w.interface.writeAll(&[_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 0, 1 });
    try w.interface.flush();
    try r.interface.readSliceAll(&buf);
    try testing.expectEqualSlices(u8, protocol.encode.not_found, &buf);

    try t.close();
}

const Tester = struct {
    server: Self,
    client: net.Stream,
    diag: ConnectionDiagnostics,
    result: anyerror!void,
    thread_handle: ?Thread,
    io: Io,
    allocator: Allocator,
    client_w_buf: [512]u8,
    client_r_buf: [512]u8,

    fn init(self: *Tester, opts: ServerOpts) !void {
        self.io = testing.io;
        self.allocator = testing.allocator;

        try self.server.init(self.allocator, self.io, opts);
        try self.server.bind("127.0.0.1:0");

        self.thread_handle = try Thread.spawn(
            .{},
            server_thread,
            .{ &self.server, &self.result, &self.diag },
        );

        var addr: linux.sockaddr.in = undefined;
        try self.server.local_addr(&addr);
        const ip4 = net.IpAddress{ .ip4 = net.Ip4Address{
            .bytes = @bitCast(addr.addr),
            .port = @byteSwap(addr.port),
        } };
        self.client = try ip4.connect(self.io, .{
            .mode = .stream,
        });
    }

    fn join(self: *Tester) anyerror!void {
        if (self.thread_handle) |h| {
            self.thread_handle = null;
            h.join();
        }
        return self.result;
    }

    fn client_writer(self: *Tester) net.Stream.Writer {
        return self.client.writer(self.io, &self.client_w_buf);
    }

    fn client_reader(self: *Tester) net.Stream.Reader {
        return self.client.reader(self.io, &self.client_r_buf);
    }

    const WriteRequestError = error{
        ReadTimeout,
        WriteTimeout,
    } || Io.Reader.Error || Io.Writer.Error;

    fn write_request(self: *Tester, bytes: []const u8, response_buf: []u8) !void {
        const timeout = Io.Duration.fromSeconds(1);

        var wbuf: [512]u8 = undefined;
        var w = self.client.writer(self.io, &wbuf);
        try try self.with_timeout(write_request_writeflush, .{ &w.interface, bytes }, timeout);

        var rbuf: [512]u8 = undefined;
        var r = self.client.reader(self.io, &rbuf);
        try try self.with_timeout(Io.Reader.readSliceAll, .{ &r.interface, response_buf }, timeout);
    }

    fn with_timeout(
        self: Tester,
        comptime func: anytype,
        args: std.meta.ArgsTuple(@TypeOf(func)),
        timeout: Io.Duration,
    ) error{Timeout}!ReturnType(func) {
        const T: type = ReturnType(func);
        const Result = union(enum) {
            io: T,
            timeout: Io.Cancelable!void,
        };
        var results: [2]Result = undefined;
        var sel: Io.Select(Result) = .init(self.io, &results);
        defer sel.cancelDiscard();
        sel.concurrent(.io, func, args) catch @panic("");
        sel.concurrent(.timeout, Io.sleep, .{ sel.io, timeout, Clock }) catch @panic("");
        return switch (sel.await() catch @panic("")) {
            .io => |res| res,
            .timeout => error.Timeout,
        };
    }

    fn ReturnType(comptime func: anytype) type {
        return @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    }

    fn write_request_writeflush(w: *Io.Writer, bytes: []const u8) Io.Writer.Error!void {
        try w.writeAll(bytes);
        try w.flush();
    }

    /// Closes the connection without closing the server.
    fn close_connection(self: *Tester) anyerror!void {
        self.client.close(self.io);
        const r = self.join();
        return r;
    }

    /// Opens a new connection.
    fn new_connection(self: *Tester) !void {
        self.thread_handle = try Thread.spawn(
            .{},
            server_thread,
            .{ &self.server, &self.result, &self.diag },
        );

        var addr: linux.sockaddr.in = undefined;
        try self.server.local_addr(&addr);
        const ip4 = net.IpAddress{ .ip4 = net.Ip4Address{
            .bytes = @bitCast(addr.addr),
            .port = @byteSwap(addr.port),
        } };
        self.client = try ip4.connect(self.io, .{
            .mode = .stream,
        });
    }

    /// Close the connection, the client, the server, and return the result of the connection.
    fn close(self: *Tester) anyerror!void {
        self.client.close(self.io);
        const r = self.join();
        self.server.close();
        return r;
    }

    fn server_thread(server: *Self, result: *anyerror!void, diag: *ConnectionDiagnostics) void {
        result.* = server.listen_and_serve_one(diag);
    }
};
