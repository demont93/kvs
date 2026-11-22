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
const assert = debug.assert;
const Clock = Io.Clock;
const Duration = Io.Duration;
const BufMap = std.BufMap;
const iovec = std.posix.iovec;
const ArrayList = std.ArrayList;
const builtin = @import("builtin");

const protocol = @import("protocol.zig");
const response = protocol.response;
const request = protocol.request;
const syscall = @import("syscall.zig");

const Self = @This();

const log = std.log.scoped(.server);

/// Assumes that the process is single threaded. If the server gets more threads, the signal may
/// land in any thread. While the variable will be set, the poll or connect may not get INTR'd.
var stop: std.atomic.Value(bool) = .init(false);

io: Io,
listener: Listener,
mem_buf: []align(std.atomic.cache_line) u8,
request_bufs: RequestBuffers,
drain_buf: []u8,
read_timeout: Duration,
write_timeout: Duration,
idle_timeout: Duration,
grace_period: Duration,
allocator: Allocator,
retry_state: RetryState,

map: BufMap,

pub const Listener = struct {
    /// Expected to be initialized in non-blocking mode.
    pub const Connection = struct {
        sock_fd: i32 = -1,

        pub const RwError = error{
            ConnectionUnusable,
            WouldBlock,
        };

        pub fn readv(self: *Connection, iovs: []iovec) RwError!usize {
            while (true) {
                const readv_rc = linux.readv(self.sock_fd, iovs.ptr, iovs.len);
                switch (linux.errno(readv_rc)) {
                    .SUCCESS => return readv_rc,
                    .INTR => continue,
                    .AGAIN => return RwError.WouldBlock,
                    .BADF,
                    .FAULT,
                    .NOTSOCK,
                    .INVAL,
                    .NOTCONN,
                    => |e| syscall.errnoBug("readv", e),
                    .CONNRESET, .PIPE => |e| {
                        log.warn("connection readv: {t}", .{e});
                        return RwError.ConnectionUnusable;
                    },
                    else => |e| {
                        log.err("connection readv: unexpected error {t}", .{e});
                        return RwError.ConnectionUnusable;
                    },
                }
            }
        }

        pub fn read(self: *Connection, buf: []u8) RwError!usize {
            while (true) {
                const read_rc = linux.read(self.sock_fd, buf.ptr, buf.len);
                switch (linux.errno(read_rc)) {
                    .SUCCESS => return read_rc,
                    .INTR => continue,
                    .CONNRESET, .PIPE => return RwError.ConnectionUnusable,
                    .AGAIN => return RwError.WouldBlock,
                    .BADF,
                    .FAULT,
                    .NOTSOCK,
                    .INVAL,
                    .NOTCONN,
                    => |e| syscall.errnoBug("read", e),
                    else => |e| {
                        log.err("connection read: unexpected error {t}", .{e});
                        return RwError.ConnectionUnusable;
                    },
                }
            }
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
                    => |e| syscall.errnoBug("write", e),
                    else => |e| return syscall.recordUnexpectedErrno(unexpected, e),
                }
            };
        }

        const ReadExactError = error{UnexpectedEof} || RwError;

        pub fn shutdown(self: *Connection) void {
            const shut_rc = linux.shutdown(self.sock_fd, linux.SHUT.WR);
            switch (linux.errno(shut_rc)) {
                .SUCCESS, .NOTCONN => {},
                else => |e| syscall.errnoBug("shutdown", e),
            }
        }

        pub fn close(self: *Connection) void {
            const rc = linux.close(self.sock_fd);
            switch (linux.errno(rc)) {
                .SUCCESS, .INTR => {},
                .BADF => |e| syscall.errnoBug("close", e),
                else => |e| logErr_deprecated("closing connection", e),
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
            else => |e| syscall.errnoBug("socket", e),
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
            else => |e| syscall.errnoBug("setsockopt", e),
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
            else => |e| syscall.errnoBug("bind", e),
        }

        const listen_rc = linux.listen(self.sock_fd, self.backlog);
        switch (linux.errno(listen_rc)) {
            .SUCCESS => {},
            .ADDRINUSE => return BindError.AddressInUse,
            else => |e| syscall.errnoBug("listen", e),
        }
    }

    pub const AcceptError = error{
        SystemResources,
        ConnectionFailed,
        Stop,
    };

    pub fn accept(self: *Listener) AcceptError!Connection {
        var peer_addr: linux.sockaddr = undefined;
        var peer_addr_len: linux.socklen_t = @sizeOf(@TypeOf(peer_addr));
        const conn_sock_fd = while (true) {
            if (stop.load(.monotonic)) {
                return error.Stop;
            }
            const accept_rc = linux.accept4(
                self.sock_fd,
                &peer_addr,
                &peer_addr_len,
                linux.SOCK.NONBLOCK,
            );
            const conn_sock_fd: i32 = switch (linux.errno(accept_rc)) {
                .SUCCESS => @intCast(accept_rc),
                .INTR => continue,
                .MFILE, .NFILE, .NOBUFS, .NOMEM => |e| {
                    log.warn("accept: {t}", .{e});
                    return AcceptError.SystemResources;
                },
                .PERM, .CONNABORTED => |e| {
                    log.warn("accept: {t}", .{e});
                    return AcceptError.ConnectionFailed;
                },
                .NETDOWN,
                .NOPROTOOPT,
                .HOSTDOWN,
                .NONET,
                .HOSTUNREACH,
                .NETUNREACH,
                => |e| {
                    log.warn("accept: {t}", .{e});
                    continue;
                },
                .BADF,
                .FAULT,
                .INVAL,
                .OPNOTSUPP,
                .PROTO,
                .AGAIN,
                => |e| syscall.errnoBug("accept", e),
                else => |e| {
                    log.err("accept: unexpected error {t}", .{e});
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
                .BADF => |e| syscall.errnoBug("close", e),
                else => |e| logErr_deprecated("closing listener", e),
            }
        }
    }

    pub const AddrError = error{
        InsufficientMemory,
        InvalidAddr,
    };

    pub fn localAddr(self: Listener, addr: *linux.sockaddr, len: *u32) AddrError!void {
        const rc = linux.getsockname(self.sock_fd, addr, len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .FAULT, .INVAL => return AddrError.InvalidAddr,
            .NOBUFS => return AddrError.InsufficientMemory,
            else => |e| syscall.errnoBug("getsockname", e),
        }
    }
};

const Request = struct {
    op: protocol.Op,
    key: []u8,
    value: ?[]u8,
};

const RequestBuffers = struct {
    frame_buffer: [request.frame_size]u8 = undefined,
    frame: ArrayList(u8),

    tail: TailBuffer,

    key_buf: ?[]u8 = null,
    key: ?ArrayList(u8),

    value_buf: ?[]u8 = null,
    value: ?ArrayList(u8),

    iovec_buf: [3]iovec = undefined,
    iovecs: ArrayList(iovec),

    stage: enum { frame, kv } = .frame,

    err_reason: ?Diagnostics,

    const Diagnostics = union(enum) {
        parse: request.InvalidFrame,
        oom,
    };

    const TailBuffer = struct {
        r: usize = 0,
        w: usize = 0,
        buf: []u8,

        fn writeRegion(self: *TailBuffer, iovs: *ArrayList(iovec)) error{TailBufferFull}!void {
            const cap = self.buf.len;
            const mask = cap - 1;

            const len = self.unused();

            const wi = self.w & mask;

            const first = @min(len, cap - wi);
            const second = len - first;

            if (first == 0 and second == 0) return error.TailBufferFull;

            if (first > 0) {
                const s = iovs.addOneAssumeCapacity();
                syscall.iovecFromSlice(s, self.buf[wi..][0..first]);
            }

            if (second > 0) {
                const s = iovs.addOneAssumeCapacity();
                syscall.iovecFromSlice(s, self.buf[0..second]);
            }
        }

        fn commit(self: *TailBuffer, n: usize) void {
            self.w +%= n;
        }

        fn unused(self: TailBuffer) usize {
            return self.buf.len - (self.w -% self.r);
        }

        fn read(self: *TailBuffer, b: []u8) usize {
            const cap = self.buf.len;
            const mask = cap - 1;

            const len = self.w -% self.r;
            const to_read = @min(len, b.len);

            const ri = self.r & mask;

            const first = @min(to_read, cap - ri);
            const second = to_read - first;

            @memcpy(b[0..first], self.buf[ri..][0..first]);
            @memcpy(b[first..][0..second], self.buf[0..second]);

            self.r +%= to_read;

            return to_read;
        }

        fn reset(self: *TailBuffer) void {
            self.r = 0;
            self.w = 0;
        }
    };

    fn init(self: *RequestBuffers, tail_buf: []u8) void {
        assert(std.math.isPowerOfTwo(tail_buf.len));
        self.tail = .{ .buf = tail_buf };
        self.frame = .initBuffer(&self.frame_buffer);
        self.iovecs = .initBuffer(&self.iovec_buf);
        self.err_reason = null;
        self.stage = .frame;
        self.key = null;
        self.key_buf = null;
        self.value = null;
        self.value_buf = null;
    }

    fn deinit(self: *RequestBuffers, allocator: Allocator) void {
        if (self.key_buf) |kb| {
            allocator.free(kb);
        }
        self.key = null;
        self.key_buf = null;
        if (self.value_buf) |vb| {
            allocator.free(vb);
        }
        self.value = null;
        self.value_buf = null;
    }

    fn reset(self: *RequestBuffers, allocator: Allocator) void {
        self.deinit(allocator);
        self.frame.items.len = 0;
        self.tail.reset();
        self.iovecs.items.len = 0;
        self.stage = .frame;
        self.err_reason = null;
    }

    fn done(self: *RequestBuffers) bool {
        return self.err_reason != null or
            (full(self.frame) and
                self.key != null and
                full(self.key.?) and
                (self.value == null or full(self.value.?)));
    }

    fn claimRequest(self: *RequestBuffers, allocator: Allocator, diag: ?*Diagnostics) ?Request {
        if (self.err_reason) |r| {
            if (diag) |d| {
                d.* = r;
                return null;
            }
        }

        assert(full(self.frame));
        assert(self.key != null and full(self.key.?));
        assert(self.value == null or full(self.value.?));
        assert(self.stage == .kv);

        const req: Request = .{
            .op = request.frameOp(self.frame_buffer),
            .key = self.key_buf.?,
            .value = self.value_buf,
        };

        self.stage = .frame;
        self.iovecs.items.len = 0;
        self.key_buf = null;
        self.key = null;
        self.value_buf = null;
        self.value = null;
        self.frame.items.len = 0;

        self.frame.items.len += self.tail.read(self.frame.unusedCapacitySlice());

        if (full(self.frame)) {
            _ = self.transitionKvStage(allocator);
        }

        return req;
    }

    fn writeRegion(self: *RequestBuffers) ?[]iovec {
        if (self.iovecs.items.len == 0) {
            switch (self.stage) {
                .frame => self.createFrameStageIovecs(),
                .kv => self.createKvStageIovecs(),
            }
        }
        return self.iovecs.items;
    }

    fn commit(self: *RequestBuffers, allocator: Allocator, n: usize) void {
        var to_commit = n;
        const iovs = self.iovecs.items;
        var remaining: usize = 0;

        for (iovs) |*iov| {
            const len = @min(to_commit, iov.len);
            iov.base += len;
            iov.len -= len;
            to_commit -= len;
            remaining += iov.len;
        }

        assert(to_commit == 0);

        if (self.stage == .frame and iovs[0].len == 0) {
            self.commitFrameStageIovecs();
            _ = self.transitionKvStage(allocator);
        } else if (self.stage == .kv and remaining == 0) {
            self.commitKvStageIovecs();
        }
    }

    fn commitKvStageIovecs(self: *RequestBuffers) void {
        self.key.?.expandToCapacity();
        if (self.value) |*v| {
            v.expandToCapacity();
        }
        self.iovecs.items.len = 0;
    }

    fn commitFrameStageIovecs(self: *RequestBuffers) void {
        self.frame.items.len = self.frame.capacity - self.iovecs.items[0].len;

        var remaining_tail: usize = 0;
        for (self.iovecs.items[1..]) |*iov| {
            remaining_tail += iov.len;
        }

        self.tail.commit(self.tail.unused() - remaining_tail);

        self.iovecs.items.len = 0;
    }

    fn transitionKvStage(self: *RequestBuffers, allocator: Allocator) bool {
        self.stage = .kv;

        var reason: request.InvalidFrame = undefined;
        if (!request.validateFrame(self.frame_buffer, &reason)) {
            self.err_reason = .{ .parse = reason };
            return false;
        }

        const kl = request.frameKeyLen(self.frame_buffer);
        self.key_buf = allocator.alloc(u8, kl) catch {
            self.err_reason = .oom;
            return false;
        };
        self.key = .initBuffer(self.key_buf.?);

        const vl = request.frameValueLen(self.frame_buffer);
        if (vl > 0) {
            self.value_buf = allocator.alloc(u8, vl) catch {
                self.err_reason = .oom;
                return false;
            };
            self.value = .initBuffer(self.value_buf.?);
        }

        self.key.?.items.len += self.tail.read(self.key.?.unusedCapacitySlice());

        if (self.value) |*v| {
            v.items.len += self.tail.read(v.unusedCapacitySlice());
        }

        return true;
    }

    fn createFrameStageIovecs(self: *RequestBuffers) void {
        appendUnused(&self.iovecs, self.frame);
        self.tail.writeRegion(&self.iovecs) catch unreachable;
    }

    fn createKvStageIovecs(self: *RequestBuffers) void {
        appendUnused(&self.iovecs, self.key.?);
        if (self.value) |*v| {
            appendUnused(&self.iovecs, v.*);
        }
    }

    inline fn full(lst: ArrayList(u8)) bool {
        return lst.items.len == lst.capacity;
    }

    inline fn appendUnused(lst: *ArrayList(iovec), s: ArrayList(u8)) void {
        const ptr = lst.addOneAssumeCapacity();
        syscall.iovecFromSlice(ptr, s.unusedCapacitySlice());
    }

    inline fn unusedCapacity(lst: ArrayList(u8)) usize {
        return lst.capacity - lst.items.len;
    }

    test "parse errors" {
        var rb: RequestBuffers = undefined;
        var tail_buf: [64]u8 = undefined;
        rb.init(&tail_buf);

        try testing.expect(!rb.done());

        const region = rb.writeRegion();
        const n = testWriteIovs(region.?, &[_]u8{0} ** 10);
        rb.commit(testing.allocator, n);

        try testing.expect(rb.done());
        var diag: Diagnostics = undefined;
        try testing.expectEqual(null, rb.claimRequest(testing.allocator, &diag));
        try testing.expectEqual(request.InvalidFrame.malformed, diag.parse);

        rb.reset(testing.allocator);
        const region2 = rb.writeRegion();
        const n2 = testWriteIovs(region2.?, "\x00\x00\x00\x00\x00\x00\x00\x01\x00");
        rb.commit(testing.allocator, n2);
        try testing.expect(rb.done());
    }

    test "batched request is retained" {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var rb: RequestBuffers = undefined;
        var tail_buf: [64]u8 = undefined;
        rb.init(&tail_buf);

        try testing.expect(!rb.done());

        const msg = try request.encodeAlloc(.get, "hello", "", arena.allocator());
        const msg2 = try request.encodeAlloc(.get, "hola", "", arena.allocator());
        const merged = try std.mem.concat(arena.allocator(), u8, &.{ msg, msg2 });

        const region = rb.writeRegion();
        const n = testWriteIovs(region.?, merged);
        rb.commit(testing.allocator, n);

        try testing.expect(rb.done());
        const req = rb.claimRequest(testing.allocator, null).?;
        defer testing.allocator.free(req.key);
        try testing.expectEqualSlices(u8, "hello", req.key);

        try testing.expect(rb.done());
        const req2 = rb.claimRequest(testing.allocator, null).?;
        defer testing.allocator.free(req2.key);
        try testing.expectEqualSlices(u8, "hola", req2.key);

        try testing.expect(!rb.done());
    }

    fn testWriteIovs(iovs: []iovec, buf: []const u8) usize {
        var i: usize = 0;
        for (iovs) |*iov| {
            const len = @min(iov.len, buf.len - i);
            @memcpy(iov.base, buf[i..][0..len]);
            i += len;
            if (i == buf.len) break;
        }

        return i;
    }
};

pub const ServerOpts = struct {
    read_timeout: Duration = .fromSeconds(6),
    write_timeout: Duration = .fromSeconds(6),
    idle_timeout: Duration = .fromSeconds(10),
    grace_period: Duration = .fromSeconds(2),
    read_buf_size: usize = 1024 * 4,
    max_drain: usize = 1024 * 4,
};

const Action = enum {
    first_read,
    subsequent_reads,
    write,
    encode,
    handler,

    fn description(self: Action) []const u8 {
        return switch (self) {
            .first_read => "reading request after idle",
            .subsequent_reads => "reading remaining request",
            .write => "writing response",
            .encode => "encoding response",
            .handler => "handling request",
        };
    }
};

const RetryState = struct {
    const max_backoff: i32 = 1600;
    const initial_backoff: i32 = 200;

    backoff: i32 = initial_backoff,

    fn wait(self: *RetryState, io: Io) void {
        debug.print("backing off for {}ms\n", .{self.backoff});
        io.sleep(.fromMilliseconds(self.backoff), .awake) catch debug.panic("can't sleep", .{});
        if (self.backoff < max_backoff) self.backoff *= 2;
    }

    fn resetBackoff(self: *RetryState) void {
        self.backoff = initial_backoff;
    }
};

pub fn init(self: *Self, allocator: Allocator, io: Io, opts: ServerOpts) error{OutOfMemory}!void {
    self.io = io;
    self.allocator = allocator;

    self.listener = .{};

    self.retry_state = .{};

    // Allocate buffers from one block.
    const mem_size = allocSize(opts.read_buf_size, opts.max_drain);
    self.mem_buf = try allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.atomic.cache_line),
        mem_size.size,
    );
    self.request_bufs.init(self.mem_buf[0..mem_size.split]);
    self.drain_buf = self.mem_buf[mem_size.split..];

    self.read_timeout = opts.read_timeout;
    self.write_timeout = opts.write_timeout;
    self.idle_timeout = opts.idle_timeout;
    self.grace_period = opts.grace_period;

    self.map = BufMap.init(allocator);

    installSigHandler();
}

pub fn close(self: *Self) void {
    self.request_bufs.deinit(self.allocator);
    self.listener.close();
    self.allocator.free(self.mem_buf);
    self.map.deinit();
}

/// Assumes that the process is single threaded. If the server gets more threads, the signal may
/// land in any thread. While the variable will be set, the poll or connect may not get INTR'd.
fn installSigHandler() void {
    var mask = linux.sigemptyset();
    linux.sigaddset(&mask, .TERM);
    linux.sigaddset(&mask, .INT);

    const act: linux.Sigaction = .{
        .flags = 0,
        .handler = .{ .handler = &sigHandler },
        .mask = mask,
    };
    switch (linux.errno(linux.sigaction(.INT, &act, null))) {
        .SUCCESS => {},
        else => |e| syscall.errnoBug("sigaction", e),
    }
    switch (linux.errno(linux.sigaction(.TERM, &act, null))) {
        .SUCCESS => {},
        else => |e| syscall.errnoBug("sigaction", e),
    }
}

fn sigHandler(signal: linux.SIG) callconv(.c) void {
    _ = signal;
    stop.store(true, .monotonic);
}

pub fn listenAndServe(
    self: *Self,
    addr: []const u8,
) void {
    self.bind(addr) catch |e| {
        debug.print("failed to bind to address {s}: {s}\n", .{ addr, @errorName(e) });
        return;
    };

    var localaddr: linux.sockaddr.in = undefined;
    self.localAddr(&localaddr) catch |e| {
        debug.print("failed to get local address: {s}\n", .{@errorName(e)});
        return;
    };

    const addr_str = formatAddr(localaddr);
    debug.print("Listening and serving on {s}\n", .{std.mem.span(addr_str[0..].ptr)});

    self.serve();
}

fn listenAndServeOne(self: *Self) Listener.AcceptError!void {
    var conn = try self.listener.accept();
    defer conn.close();
    try self.handleConnection(&conn);
}

pub fn bind(self: *Self, addr: []const u8) Listener.BindError!void {
    return self.listener.bind(addr);
}

pub fn serve(self: *Self) void {
    while (true) {
        var conn = if (self.listener.accept()) |conn| blk: {
            self.retry_state.resetBackoff();
            break :blk conn;
        } else |err| switch (err) {
            error.Stop => {
                log.info("stopping the server", .{});
                return;
            },
            error.ConnectionFailed => {
                self.retry_state.resetBackoff();
                continue;
            },
            error.SystemResources => {
                self.retry_state.wait(self.io);
                continue;
            },
        };

        const result = self.handleConnection(&conn);
        conn.close();
        result catch |e| {
            switch (e) {
                error.Stop => {
                    log.info("stopping the server", .{});
                    return;
                },
            }
        };
    }
}

fn handleConnection(self: *Self, conn: *Listener.Connection) error{Stop}!void {
    defer self.request_bufs.reset(self.allocator);
    var should_continue = true;

    while (should_continue) {
        should_continue = try self.handleRequest(conn);
    }
}

fn handleRequest(self: *Self, conn: *Listener.Connection) error{Stop}!bool {
    const resp, const free = self.handleRequestBeforeWrite(conn) catch |err| switch (err) {
        error.Stop => |e| return e,
        error.Finished => return false,
        error.ConnectionUnusable => {
            log.info("connection: unusable", .{});
            return false;
        },
        else => |respond_err| {
            log.info("connection: {t}", .{respond_err});
            const err_response = switch (respond_err) {
                error.SystemResources => response.internal,
                error.BadRequest => response.invalid,
                error.Timeout => response.timeout,
            };
            self.writeDrain(conn, err_response);
            return false;
        },
    };
    defer if (free) self.allocator.free(resp);

    self.writeAll(conn, resp) catch |err| switch (err) {
        error.ConnectionUnusable => {
            log.info("connection: unusable", .{});
            return false;
        },
        error.Timeout => {
            log.info("connection: write timeout", .{});
            return false;
        },
    };

    return true;
}

const BeforeWriteError = error{
    Timeout,
    SystemResources,
    Stop,
    ConnectionUnusable,
    BadRequest,
    Finished,
};

fn handleRequestBeforeWrite(
    self: *Self,
    conn: *Listener.Connection,
) BeforeWriteError!struct { []const u8, bool } {
    const req = try self.readRequest(conn);

    return self.handler(req) catch |e| {
        log.warn("request handler: {t}", .{e});
        return error.SystemResources;
    };
}

fn handler(self: *Self, req: Request) error{OutOfMemory}!struct { []const u8, bool } {
    switch (req.op) {
        .get => {
            defer self.allocator.free(req.key);

            if (self.map.get(req.key)) |v| {
                const msg = try response.value(self.allocator, v);
                return .{ msg, true };
            } else {
                return .{ response.not_found, false };
            }
        },
        .del => {
            defer self.allocator.free(req.key);

            if (self.map.hash_map.fetchRemove(req.key)) |kv| {
                self.map.hash_map.allocator.free(kv.key);
                self.map.hash_map.allocator.free(kv.value);
                return .{ response.ok, false };
            } else {
                return .{ response.not_found, false };
            }
        },
        .set => {
            if (self.map.putMove(req.key, req.value.?)) |_| {
                return .{ response.ok, false };
            } else |e| {
                self.allocator.free(req.key);
                self.allocator.free(req.value.?);
                return e;
            }
        },
    }
}

const ReadRequestError = error{
    ConnectionUnusable,
    SystemResources,
    BadRequest,
    Timeout,
    Stop,
    Finished,
};

fn readRequest(
    self: *Self,
    conn: *Listener.Connection,
) ReadRequestError!Request {
    const idle_deadline = self.makeDeadline(self.idle_timeout);
    var fds: [1]linux.pollfd = .{syscall.pollfd(conn.sock_fd, linux.POLL.IN)};

    if (!self.request_bufs.done()) {
        const n_read = self.readConnection(
            conn,
            &fds,
            idle_deadline,
            .stoppable,
        ) catch |err| switch (err) {
            error.Timeout => |e| {
                log.info("read request: idle connection timeout", .{});
                return e;
            },
            else => |e| return e,
        };

        if (n_read == 0) {
            return error.Finished;
        }

        self.request_bufs.commit(self.allocator, n_read);
    }

    const read_deadline = self.makeDeadline(self.read_timeout);

    while (!self.request_bufs.done()) {
        const n_read = self.readConnection(
            conn,
            &fds,
            read_deadline,
            .non_stoppable,
        ) catch |err| switch (err) {
            error.Timeout => |e| {
                log.info("read request: read timeout", .{});
                return e;
            },
            else => |e| return e,
        };

        if (n_read == 0) {
            log.debug("read request: unexpected end of file", .{});
            return error.BadRequest;
        }

        self.request_bufs.commit(self.allocator, n_read);
    }

    var rb_diag: RequestBuffers.Diagnostics = undefined;
    return self.request_bufs.claimRequest(self.allocator, &rb_diag) orelse {
        const err = switch (rb_diag) {
            .oom => blk: {
                log.warn("parse request: out of memory", .{});
                break :blk error.SystemResources;
            },
            .parse => |v| blk: {
                log.debug("parse request: {t}", .{v});
                break :blk error.BadRequest;
            },
        };
        return err;
    };
}

const ReadConnectionError = error{
    ConnectionUnusable,
    SystemResources,
    Timeout,
    Stop,
};

const Stoppable = enum {
    stoppable,
    non_stoppable,
};

fn readConnection(
    self: *Self,
    conn: *Listener.Connection,
    fds: *[1]linux.pollfd,
    deadline: Clock.Timestamp,
    stoppable: Stoppable,
) ReadConnectionError!usize {
    return while (true) {
        const iovs = self.request_bufs.writeRegion().?;
        const read_result = conn.readv(iovs);

        if (read_result) |n| break n else |err| switch (err) {
            error.WouldBlock => {},
            else => |e| return e,
        }

        while (true) {
            if (stoppable == .stoppable and stop.load(.monotonic)) return error.Stop;
            _ = syscall.pollintr(
                self.io,
                fds,
                deadline,
                null,
            ) catch |err| switch (err) {
                error.Intr => continue,
                error.OutOfMemory, error.TooManyPollFds => |e| {
                    log.warn("poll: {t}", .{e});
                    return error.SystemResources;
                },
                error.Unexpected => return error.ConnectionUnusable,
                else => |e| return e,
            };
            break;
        }
    };
}

fn timeoutRemainingMs(self: Self, deadline: Clock.Timestamp) ?i32 {
    const timeout = deadline.durationFromNow(self.io).raw.toMilliseconds();
    return if (timeout > 0) @intCast(timeout) else null;
}

const WriteError = error{
    Timeout,
    ConnectionUnusable,
};

/// Shuts down the write side of the connection. Caller must close after calling this.
fn writeDrain(self: *Self, conn: *Listener.Connection, buf: []const u8) void {
    self.writeAll(conn, buf) catch return;
    conn.shutdown();
    self.drain(conn);
}

fn drain(self: *Self, conn: *Listener.Connection) void {
    const deadline = self.makeDeadline(self.grace_period);
    var pollfd = syscall.pollfd(conn.sock_fd, linux.POLL.IN);
    var i: usize = 0;
    while (i < self.drain_buf.len) {
        _ = syscall.poll(
            self.io,
            @as(*[1]linux.pollfd, &pollfd),
            deadline,
            null,
        ) catch |e| switch (e) {
            error.Timeout, error.Unexpected => return,
            error.TooManyPollFds => syscall.zerrnoBug("poll", e),
            error.OutOfMemory => log_deprecated("OutOfMemory when draining request\n", .{}),
        };

        const n = conn.read(self.drain_buf[i..]) catch return;
        if (n == 0) return;
        i += n;
    }
}

fn writeAll(
    self: *Self,
    conn: *Listener.Connection,
    buf: []const u8,
) WriteError!void {
    const deadline = self.makeDeadline(self.write_timeout);
    try self.writeAllPoll(conn, buf, deadline);
}

fn writeAllPoll(
    self: *Self,
    conn: *Listener.Connection,
    buf: []const u8,
    deadline: Clock.Timestamp,
) WriteError!void {
    syscall.sendAllPoll(
        conn.sock_fd,
        buf,
        deadline,
        self.io,
        null,
    ) catch |err| switch (err) {
        error.Timeout => |e| return e,
        error.Unexpected => |e| {
            log.err("write polling: unexpected error {t}", .{e});
            return error.ConnectionUnusable;
        },
        error.ConnectionReset, error.OutOfMemory => |e| {
            log.warn("write polling: {t}", .{e});
            return error.ConnectionUnusable;
        },
        else => |e| syscall.zerrnoBug("send | poll", e),
    };
}

fn localAddr(self: Self, addr: *linux.sockaddr.in) Listener.AddrError!void {
    var len: u32 = @sizeOf(@TypeOf(addr));
    try self.listener.localAddr(@ptrCast(addr), &len);
}

fn formatAddr(localaddr: linux.sockaddr.in) [22:0]u8 {
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

/// Determines the alloc size for a read buffer and a drain buffer, rounded up to cache line size.
fn allocSize(req_read_buf: usize, req_drain_buf: usize) struct { size: usize, split: usize } {
    const cache_line = std.atomic.cache_line;
    const mask: usize = cache_line - 1;
    const read_buf: usize = if (req_read_buf & mask > 0)
        (req_read_buf & ~mask) + cache_line
    else
        req_read_buf & ~mask;
    return .{ .size = read_buf + req_drain_buf, .split = read_buf };
}

/// Expects a non-negative duration. Fails if duration is too long.
fn toTimeval(duration: Duration) ?linux.timeval {
    assert(duration.nanoseconds >= 0);
    const us: i64 = @intCast(@divTrunc(@rem(duration.nanoseconds, 1_000_000_000), 1000));
    const s = math.cast(isize, duration.toSeconds()) orelse return null;
    return .{ .sec = s, .usec = us };
}

fn makeDeadline(self: Self, duration: Duration) Clock.Timestamp {
    return Clock.Timestamp.fromNow(
        self.io,
        Io.Clock.Duration{ .raw = duration, .clock = .awake },
    );
}

fn now(self: Self) Clock.Timestamp {
    return Clock.Timestamp.now(self.io, Clock);
}

fn log_deprecated(comptime fmt: []const u8, args: anytype) void {
    debug.print(fmt, args);
}

fn logErr_deprecated(msg: []const u8, e: anytype) void {
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
        &[_]u8{ @intFromEnum(response.Code.NotFound), 0, 0, 0, 0 },
        &response_buf,
    );

    try t.close();
}

test "slow writing client gets read timeout" {
    var t: Tester = undefined;
    try t.init(.{ .read_timeout = .fromMilliseconds(400) });
    var w = t.client_writer();
    const n_written = try w.interface.write(&[_]u8{0});
    try testing.expectEqual(1, n_written);
    try w.interface.flush();
    var resp: [5]u8 = undefined;
    var r = t.client_reader();
    try r.interface.readSliceAll(&resp);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ @intFromEnum(response.Code.Timeout), 0, 0, 0, 0 },
        &resp,
    );
    try t.close();
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
    var resp: [20]u8 = undefined;
    var r = t.client_reader();
    try r.interface.readSliceAll(&resp);
    try testing.io.sleep(.fromMilliseconds(400), .awake);
    try t.close();
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
    try t.close();
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
    try t.close();
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
    try testing.expectEqualSlices(u8, response.ok, &resp1);

    var resp2: [8]u8 = undefined;
    try w.interface.writeAll(&get);
    try w.interface.flush();
    try r.interface.readSliceAll(&resp2);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 3, 4, 5, 6 }, &resp2);

    var resp3: [5]u8 = undefined;
    try w.interface.writeAll(&del);
    try w.interface.flush();
    try r.interface.readSliceAll(&resp3);
    try testing.expectEqualSlices(u8, response.ok, &resp3);

    var resp4: [5]u8 = undefined;
    try w.interface.writeAll(&get);
    try w.interface.flush();
    try r.interface.readSliceAll(&resp4);
    try testing.expectEqualSlices(u8, response.not_found, &resp4);

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
    try testing.expectEqualSlices(u8, response.not_found, &buf);

    try testing.io.sleep(.fromMilliseconds(180), .awake);

    try w.interface.writeAll(&[_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 0, 1 });
    try w.interface.flush();
    try r.interface.readSliceAll(&buf);
    try testing.expectEqualSlices(u8, response.not_found, &buf);

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
    try testing.expectEqualSlices(u8, response.ok, &buf);
    const result = t.close_connection();
    errdefer debug.print("\n{any}\n", .{result});

    try t.new_connection();

    w = t.client_writer();
    r = t.client_reader();

    try w.interface.writeAll(&[_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 0, 1 });
    try w.interface.flush();
    try r.interface.readSliceAll(&buf);
    try testing.expectEqualSlices(u8, response.not_found, &buf);

    try t.close();
}

const Tester = struct {
    server: Self,
    client: net.Stream,
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
            .{ &self.server, &self.result },
        );

        var addr: linux.sockaddr.in = undefined;
        try self.server.localAddr(&addr);
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
        const timeout = Duration.fromSeconds(1);

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
        timeout: Duration,
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
        sel.concurrent(.timeout, Io.sleep, .{ sel.io, timeout, .awake }) catch @panic("");
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
            .{ &self.server, &self.result },
        );

        var addr: linux.sockaddr.in = undefined;
        try self.server.localAddr(&addr);
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

    fn server_thread(server: *Self, result: *anyerror!void) void {
        result.* = server.listenAndServeOne();
    }
};
