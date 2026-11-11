const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const SmpAllocator = std.heap.SmpAllocator;
const Io = std.Io;
const assert = std.debug.assert;
const linux = std.os.linux;
const Err = lib.Err;
const errno = linux.errno;

const kvs = @import("kvs");

const lib = @import("lib.zig");

var process_ctx: ProcessCtx = undefined;

const CountAllocator = struct {
    smp_alloc: SmpAllocator = .{},
    alloc_count: usize = 0,
    remap_count: usize = 0,
    resize_count: usize = 0,

    const VTable = Allocator.VTable{
        .alloc = alloc,
        .free = SmpAllocator.vtable.free,
        .remap = remap,
        .resize = resize,
    };

    fn allocator(self: *CountAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &VTable,
        };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        var self: *CountAllocator = @ptrCast(@alignCast(context));
        const res = SmpAllocator.vtable.alloc(&self.smp_alloc, len, alignment, ret_addr);
        if (res != null) {
            self.alloc_count += 1;
        }
        return res;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        var self: *CountAllocator = @ptrCast(@alignCast(context));
        const res = SmpAllocator.vtable.remap(
            &self.smp_alloc,
            memory,
            alignment,
            new_len,
            ret_addr,
        );
        if (res != null) {
            self.remap_count += 1;
        }
        return res;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        var self: *CountAllocator = @ptrCast(@alignCast(context));
        const res = SmpAllocator.vtable.resize(
            &self.smp_alloc,
            memory,
            alignment,
            new_len,
            ret_addr,
        );
        if (res) {
            self.resize_count += 1;
        }
        return res;
    }
};

const ProcessCtx = struct {
    count_allocator: *CountAllocator,
    report: *Report,
    state: enum { empty, before_measurement, after_measurement },
};

pub const Report = struct {
    alloc_count: usize = 0,
    remap_count: usize = 0,
    resize_count: usize = 0,
};

pub const Message = enum(u8) {
    start_counting,
    end,
};

pub const Context = struct {
    cpu: linux.cpu_set_t,
    sock: i32,
    port: u16,
    count_allocs: bool,
    report: Report,
};

pub const ExitCode = enum(u8) {
    success = 0,
    err = 1,

    pub fn value(self: ExitCode) u8 {
        return @intFromEnum(self);
    }
};

pub fn processMain(arg: usize) callconv(.c) u8 {
    const ctx: Context = @ptrFromInt(arg);
    if (server(ctx)) |_| {
        return ExitCode.success.value();
    } else |_| {
        return ExitCode.success.value();
    }
}

fn server(ctx: Context) !void {
    defer {
        switch (errno(linux.close(ctx.sock))) {
            .SUCCESS => {},
            else => |e| lib.errnoUnexpected("close", e),
        }
    }

    try linux.sched_setaffinity(0, &ctx.cpu);

    const smp_allocator = std.heap.smp;
    const counting_allocator = CountAllocator{};

    const allocator = if (ctx.count_allocs)
        counting_allocator.allocator()
    else
        smp_allocator;

    const threaded = std.Io.Threaded.init(smp_allocator, .{});
    defer threaded.deinit();

    const io = threaded.io();

    var report: Report = undefined;

    if (ctx.count_allocs) {
        installSigHandler(counting_allocator, &report);
    }

    var serv: kvs.Server = undefined;
    serv.init(allocator, io, .{}) catch |err| return switch (err) {
        error.OutOfMemory => lib.logErr("out of memory initializing server\n", .{}),
    };
    defer serv.close();

    var addr_buf: [15]u8 = undefined;
    const addr = try std.fmt.bufPrint(&addr_buf, "127.0.0.1:{}", .{ctx.port});
    serv.listen_and_serve(addr);

    if (ctx.count_allocs) {
        try sendReport(ctx.sock, &report);
    }
}

/// Must be called only once per process.
fn installSigHandler(count_allocator: *CountAllocator, report: *Report) void {
    process_ctx.count_allocator = count_allocator;
    process_ctx.report = report;
    process_ctx.state = .empty;

    const zeromask = linux.sigemptyset();
    const usr_sigaction = linux.Sigaction{
        .flags = 0,
        .mask = zeromask,
        .handler = .{ .handler = &snapshotAllocations },
    };
    sigaction(.USR1, &usr_sigaction);
    sigaction(.USR2, &usr_sigaction);
}

fn sigaction(s: linux.SIG, sigact: *linux.Sigaction) void {
    switch (errno(linux.sigaction(s, sigact, null))) {
        .SUCCESS => {},
        .FAULT, .INVAL => |e| lib.errnoBug("sigaction", e),
    }
}

fn snapshotAllocations(s: linux.SIG) callconv(.c) void {
    const a = &process_ctx.count_allocator;
    const r = &process_ctx.report;

    switch (s) {
        .USR1 => {
            if (process_ctx.state != .empty) {
                std.process.abort();
            }
            process_ctx.state = .before_measurement;

            r.alloc_count = a.alloc_count;
            r.remap_count = a.remap_count;
            r.resize_count = a.resize_count;
        },
        .USR2 => {
            if (process_ctx.state != .before_measurement) {
                std.process.abort();
            }
            process_ctx.state = .after_measurement;

            r.alloc_count = a.alloc_count - r.alloc_count;
            r.remap_count = a.remap_count - r.remap_count;
            r.resize_count = a.resize_count - r.resize_count;
        },
        else => unreachable,
    }
}

fn sendReport(sock: i32, report: *const Report) !void {
    const report_buf: *const [@sizeOf(Report)]u8 = @ptrCast(&report);
    try lib.sendAll(sock, report_buf);
}

fn recvEnd(sock: i32) !void {
    var buf: [1]u8 = undefined;
    recvAll(sock, &buf) catch |err| return switch (err) {
        error.UnexpectedEof => lib.logErr("unexpected eof expecting start\n", .{}),
        error.Err => error.Err,
    };
    if (buf[0] != @intFromEnum(Message.end)) {
        return lib.logErr("received invalid message expecting start: {}\n", .{buf[0]});
    }
}

fn recvAll(sock: i32, buf: []u8) (error{UnexpectedEof} || Err)!void {
    lib.recvAll(sock, &buf) catch |err| return switch (err) {
        error.UnexpectedEof => error.UnexpectedEof,
        error.Unexpected => Err.Err,
        error.ClosedByPeer => lib.logErr("connection closed\n", .{}),
    };
}
