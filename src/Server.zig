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

const protocol = @import("protocol.zig");

const Self = @This();

pub const Listener = struct {
    /// Expected to be initialized in non-blocking mode.
    pub const Connection = struct {
        sock_fd: i32 = -1,

        pub const RwError = error{
            ConnectionReset,
            NetworkDown,
            Unreachable,
            Unexpected,
            WouldBlock,
        };

        pub fn read(self: *Connection, buf: []u8) RwError!usize {
            return while (true) {
                const read_rc = linux.read(self.sock_fd, buf.ptr, buf.len);
                switch (linux.errno(read_rc)) {
                    .SUCCESS => break read_rc,
                    .INTR => continue,
                    .CONNRESET, .PIPE => return RwError.ConnectionReset,
                    .NETDOWN => return RwError.NetworkDown,
                    .AGAIN => return RwError.WouldBlock,
                    .TIMEDOUT,
                    .HOSTUNREACH,
                    .NETUNREACH,
                    .HOSTDOWN,
                    .NONET,
                    => return RwError.Unreachable,
                    .BADF,
                    .FAULT,
                    .NOTSOCK,
                    .INVAL,
                    .NOTCONN,
                    => |e| unexpected_syscall("read", e),
                    else => |e| {
                        log_syscall_err("read", e);
                        return RwError.Unexpected;
                    },
                }
            };
        }

        pub fn write(self: *Connection, buf: []const u8) RwError!usize {
            return while (true) {
                const write_rc = linux.write(self.sock_fd, buf.ptr, buf.len);
                switch (linux.errno(write_rc)) {
                    .SUCCESS => break write_rc,
                    .INTR => continue,
                    .CONNRESET, .PIPE => return RwError.ConnectionReset,
                    .NETDOWN => return RwError.NetworkDown,
                    .AGAIN => return RwError.WouldBlock,
                    .TIMEDOUT,
                    .HOSTUNREACH,
                    .NETUNREACH,
                    .HOSTDOWN,
                    .NONET,
                    => return RwError.Unreachable,
                    .BADF,
                    .FAULT,
                    .NOTSOCK,
                    .INVAL,
                    .NOTCONN,
                    => |e| unexpected_syscall("write", e),
                    else => |e| {
                        log_syscall_err("write", e);
                        return RwError.Unexpected;
                    },
                }
            };
        }

        const ReadExactError = error{UnexpectedEof} || RwError;

        pub fn read_exact(self: *Connection, buf: []u8) ReadExactError!void {
            var i: usize = 0;
            while (i < buf.len) {
                const n = try self.read(buf[i..buf.len]);
                if (n == 0) {
                    return ReadExactError.UnexpectedEof;
                }
                i += n;
            }
        }

        pub fn shutdown(self: *Connection) void {
            const shut_rc = linux.shutdown(self.sock_fd, linux.SHUT.WR);
            switch (linux.errno(shut_rc)) {
                .SUCCESS, .NOTCONN => {},
                else => |e| unexpected_syscall("shutdown", e),
            }
        }

        pub fn close(self: *Connection) void {
            const rc = linux.close(self.sock_fd);
            switch (linux.errno(rc)) {
                .SUCCESS, .INTR => {},
                .BADF => |e| unexpected_syscall("close", e),
                else => |e| log_syscall_err("close", e),
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
        const socket_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
        switch (linux.errno(socket_rc)) {
            .SUCCESS => self.sock_fd = @intCast(socket_rc),
            .ACCES => return BindError.PermissionDenied,
            .MFILE, .NFILE => return BindError.TooManyOpenFiles,
            .NOBUFS, .NOMEM => return BindError.InsufficientMemory,
            else => |e| unexpected_syscall("socket", e),
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
            else => |e| unexpected_syscall("setsockopt", e),
        }

        const addr_u, const port_u = Listener.parse_addr(addr) orelse
            return BindError.InvalidAddress;
        const sock_addr = linux.sockaddr.in{ .addr = addr_u, .port = port_u };
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
            else => |e| unexpected_syscall("bind", e),
        }

        const listen_rc = linux.listen(self.sock_fd, self.backlog);
        switch (linux.errno(listen_rc)) {
            .SUCCESS => {},
            .ADDRINUSE => return BindError.AddressInUse,
            else => |e| unexpected_syscall("listen", e),
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
                .PROTO,
                .NOPROTOOPT,
                .HOSTDOWN,
                .NONET,
                .HOSTUNREACH,
                .OPNOTSUPP,
                .NETUNREACH,
                => continue,
                else => |e| unexpected_syscall("accept", e),
            };
            break conn_sock_fd;
        };

        return Connection{ .sock_fd = conn_sock_fd };
    }

    fn parse_addr(addr: []const u8) ?struct { u32, u16 } {
        var addr_u: u32 = 0;
        var octet: u32 = 0;
        var i: usize = 0;
        var pos: i32 = 0;
        var is_zero = false;

        for (0..4) |n_octet| {
            octet = 0;
            pos = 0;
            is_zero = false;

            while (i < addr.len and pos < 3 and addr[i] >= '0' and addr[i] <= '9') {
                if (pos == 0 and addr[i] == '0') is_zero = true;
                if (pos == 1 and is_zero) return null;

                octet *= 10;
                octet += addr[i] - '0';

                pos += 1;
                i += 1;
            }
            if (i == addr.len or
                pos == 0 or
                (n_octet == 3 and addr[i] != ':') or
                (n_octet < 3 and addr[i] != '.') or
                octet > math.maxInt(u8))
            {
                return null;
            }

            addr_u <<= 8;
            addr_u |= octet;
            i += 1;
        }

        var port: u32 = 0;
        const port_start = i;
        is_zero = false;
        while (i < addr.len and port <= math.maxInt(u16) and addr[i] >= '0' and addr[i] <= '9') {
            if (i == port_start and addr[i] == '0') is_zero = true;
            if (i == port_start + 1 and is_zero) return null;
            port *= 10;
            port += addr[i] - '0';

            i += 1;
        }
        if (i < addr.len or i == port_start or port > math.maxInt(u16)) {
            return null;
        }

        return switch (builtin.target.cpu.arch.endian()) {
            .big => .{ addr_u, @truncate(port) },
            .little => .{ @byteSwap(addr_u), @byteSwap(@as(u16, @truncate(port))) },
        };
    }

    pub fn close(self: *Listener) void {
        if (self.sock_fd != -1) {
            const close_rc = linux.close(self.sock_fd);
            switch (linux.errno(close_rc)) {
                .SUCCESS, .INTR => {},
                .BADF => |e| unexpected_syscall("close", e),
                else => |e| log_syscall_err("close", e),
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
            else => |e| unexpected_syscall("getsockname", e),
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
        result catch {
            debug.print(
                "connection error {} while {s}\n",
                .{ diag.details, diag.action.description() },
            );
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

const RequestError = error{
    ConnectionUnusable,
    BadRequest,
    ReadTimeout,
    Unexpected,
    OutOfMemory,
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
        const response = switch (err) {
            error.ConnectionUnusable => |e| return e,
            error.OutOfMemory, error.Unexpected => encode.internal,
            error.BadRequest => encode.invalid,
            error.ReadTimeout => encode.timeout,
        };
        self.write_drain(conn, response);
        return err;
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
        const err_out = switch (err) {
            error.ConnectionReset,
            error.NetworkDown,
            error.Unreachable,
            error.WriteTimeout,
            => RequestError.ConnectionUnusable,
            error.Unexpected => RequestError.Unexpected,
            error.OutOfMemory => |e| e,
        };
        diag.record(.Write, err);
        return err_out;
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
    ConnectionUnusable,
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
                error.OutOfMemory, error.Unexpected => |e2| e2,
                error.ConnectionReset,
                error.NetworkDown,
                error.Unreachable,
                => error.ConnectionUnusable,
            };
            diag.record(.FirstRead, e);
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
            const err = switch (e) {
                error.ReadTimeout, error.OutOfMemory, error.Unexpected => |e2| e2,
                error.ConnectionReset,
                error.NetworkDown,
                error.Unreachable,
                => error.ConnectionUnusable,
            };
            diag.record(.SubsequentReads, e);
            return err;
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
    NetworkDown,
    Unreachable,
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
        var pollfd = linux.pollfd{
            .fd = conn.sock_fd,
            .events = linux.POLL.IN,
            .revents = 0,
        };

        var n = conn.read(self.read_buf.write()) catch |e| switch (e) {
            error.ConnectionReset,
            error.NetworkDown,
            error.Unreachable,
            error.Unexpected,
            => |err| return err,
            error.WouldBlock => 0,
        };

        if (n == 0) {
            const poll_result: i32 = while (true) {
                const timeout = self.timeout_remaining_ms(deadline) orelse return error.ReadTimeout;
                const poll_rc = linux.poll(@as(*[1]linux.pollfd, &pollfd), 1, timeout);
                switch (linux.errno(poll_rc)) {
                    .SUCCESS => break @intCast(poll_rc),
                    .NOMEM => return error.OutOfMemory,
                    .INTR => continue,
                    else => |e| unexpected_syscall("poll", e),
                }
            };

            if (poll_result == 0) {
                return error.ReadTimeout;
            }

            n = conn.read(self.read_buf.write()) catch |e| switch (e) {
                error.ConnectionReset,
                error.NetworkDown,
                error.Unreachable,
                error.Unexpected,
                => |err| return err,
                error.WouldBlock => unexpected_syscall("read", linux.E.AGAIN),
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
    NetworkDown,
    Unreachable,
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
    var pollfd = linux.pollfd{
        .events = linux.POLL.IN,
        .fd = conn.sock_fd,
        .revents = 0,
    };
    var i: usize = 0;
    while (i < self.drain_buf.len) {
        const timeout = self.timeout_remaining_ms(deadline) orelse return;
        const poll_rc = linux.poll(@as(*[1]linux.pollfd, &pollfd), 1, timeout);
        const poll_result: i32 = switch (linux.errno(poll_rc)) {
            .SUCCESS => @intCast(poll_rc),
            .NOMEM => return,
            .INTR => continue,
            else => |e| unexpected_syscall("poll", e),
        };
        if (poll_result == 0) return;

        const n = conn.read(self.drain_buf[i..]) catch return;
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
    var pollfd = linux.pollfd{
        .fd = conn.sock_fd,
        .events = linux.POLL.OUT,
        .revents = 0,
    };

    var i: usize = conn.write(buf) catch |e| switch (e) {
        error.WouldBlock => 0,
        error.ConnectionReset,
        error.NetworkDown,
        error.Unreachable,
        error.Unexpected,
        => |err| return err,
    };

    while (i < buf.len) {
        const poll_result: i32 = while (true) {
            const timeout = self.timeout_remaining_ms(deadline) orelse return error.WriteTimeout;
            const poll_rc = linux.poll(@as(*[1]linux.pollfd, &pollfd), 1, timeout);
            switch (linux.errno(poll_rc)) {
                .SUCCESS => break @intCast(poll_rc),
                .NOMEM => return error.OutOfMemory,
                .INTR => continue,
                else => |e| unexpected_syscall("poll", e),
            }
        };
        if (poll_result == 0) {
            return error.WriteTimeout;
        }

        const n = conn.write(buf[i..]) catch |e| switch (e) {
            error.WouldBlock => unexpected_syscall("write", linux.E.AGAIN),
            error.ConnectionReset,
            error.NetworkDown,
            error.Unreachable,
            error.Unexpected,
            => |err| return err,
        };
        i += n;
    }
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

fn unexpected_syscall(syscall_name: []const u8, e: linux.E) noreturn {
    debug.panic("unexpected error on {s} call: {}\n", .{ syscall_name, e });
}

fn log_syscall_err(syscall_name: []const u8, e: linux.E) void {
    debug.print("unexpected error on {s} call: {}\n", .{ syscall_name, e });
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

test {
    testing.refAllDecls(@This());
}

test "octet parser" {
    const addr_u, const port_u = Listener.parse_addr("192.168.1.1:8080") orelse .{ 0, 0 };
    switch (builtin.target.cpu.arch.endian()) {
        .big => {
            try testing.expectEqual(0xc0a80101, addr_u);
            try testing.expectEqual(0x1f90, port_u);
        },
        .little => {
            try testing.expectEqual(0x0101a8c0, addr_u);
            try testing.expectEqual(0x901f, port_u);
        },
    }
}

test "fuzz the address parse function" {
    try testing.fuzz({}, fuzz_addr_parse_function, .{});
}

fn fuzz_addr_parse_function(context: void, smith: *testing.Smith) !void {
    _ = context;
    var addr_buf: [40]u8 = undefined;

    while (!smith.eos()) {
        const addr = gen_str_addr(smith, &addr_buf);
        const full_addr = gen_full_addr(smith, &addr_buf, addr.len);

        const result = Listener.parse_addr(full_addr);
        const resok = if (result) |_| true else false;

        const sep_ix = std.mem.findScalar(u8, full_addr, ':');
        const is_correct_sep = sep_ix != null;

        const port_slice = if (sep_ix) |i| full_addr[i + 1 ..] else null;

        const port_has_no_leading_zero = if (sep_ix) |i|
            full_addr.len < i + 3 or full_addr[i + 1] != '0'
        else
            true;

        const port_parse_is_ok = if (port_slice) |s|
            if (std.fmt.parseUnsigned(u16, s, 10)) |_| true else |_| false
        else
            false;

        const port_is_ascii = if (port_slice) |s| for (s) |c| {
            if (c < '0' or c > '9') break false;
        } else blk: {
            break :blk true;
        } else false;

        const has_port = if (port_slice) |s| s.len > 0 else false;

        const std_addr = if (sep_ix) |i| full_addr[0..i] else full_addr;

        const std_result = Io.net.Ip4Address.parse(std_addr, 0);

        const stdok = if (std_result) |_| true else |_| false;

        errdefer debug.print(
            \\
            \\Address: |{s}|,
            \\Address s: |{x}|,
            \\
            \\stdok: {},
            \\is_correct_sep: {},
            \\port_is_ascii: {},
            \\port_has_no_leading_zero: {},
            \\post_parse_is_ok: {},
            \\has_port: {},
            \\
            \\resok: {},
            \\
        ,
            .{
                full_addr,
                full_addr,
                stdok,
                is_correct_sep,
                port_is_ascii,
                port_has_no_leading_zero,
                port_parse_is_ok,
                has_port,
                resok,
            },
        );

        try testing.expectEqual(
            stdok and is_correct_sep and port_is_ascii and port_has_no_leading_zero and port_parse_is_ok and has_port,
            resok,
        );
        if (std_result) |stdres| {
            if (result) |res| {
                const stdresu32addr = std.mem.readInt(u32, &stdres.bytes, .big);
                try testing.expectEqual(@byteSwap(stdresu32addr), res[0]);
            }
        } else |_| {}
    }
}

fn gen_full_addr(s: *testing.Smith, addr_buf: *[40]u8, addr_len: usize) []u8 {
    addr_buf[addr_len] = s.valueWeighted(u8, &[_]testing.Smith.Weight{
        .rangeLessThan(u8, 0, ':', 1),
        .value(u8, ':', 254 * 9),
        .rangeAtMost(u8, ':' + 1, 255, 1),
    });
    const port_buf = addr_buf[addr_len + 1 .. addr_len + 1 + 6];
    const port_len = s.sliceWeightedBytes(port_buf, &[_]testing.Smith.Weight{
        .rangeLessThan(u8, 0, '9', 1),
        .rangeAtMost(u8, '0', '9', 72),
        .rangeAtMost(u8, '9' + 1, 255, 1),
    });
    return addr_buf[0 .. addr_len + 1 + port_len];
}

fn gen_str_addr(s: *testing.Smith, addr_buf: *[40]u8) []u8 {
    const n_octets = s.valueRangeAtMost(u32, 0, 5);
    var addr_index: usize = 0;
    for (0..n_octets) |i| {
        if (i != 0) {
            addr_buf[addr_index] = s.valueWeighted(u8, &[_]testing.Smith.Weight{
                .rangeLessThan(u8, 0, '.', 1),
                .value(u8, '.', 254 * 9),
                .rangeAtMost(u8, '.' + 1, 255, 1),
            });
            addr_index += 1;
        }
        const byte_len = gen_str_byte(s, addr_buf[addr_index .. addr_index + 5]);
        addr_index += byte_len;
    }

    return addr_buf[0..addr_index];
}

fn gen_str_byte(s: *testing.Smith, buf: []u8) usize {
    return s.sliceWeightedBytes(buf, &[_]testing.Smith.Weight{
        .rangeLessThan(u8, 0, '0', 1),
        .rangeAtMost(u8, '0', '9', 254 * 9),
        .rangeAtMost(u8, '9' + 1, 255, 1),
    });
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
    try testing.expectError(error.ConnectionUnusable, t.close());
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
