const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const SmpAllocator = std.heap.SmpAllocator;
const Io = std.Io;
const assert = std.debug.assert;
const linux = std.os.linux;
const Err = lib.Err;

const kvs = @import("kvs");

const lib = @import("lib.zig");

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

pub const Report = struct {
    allocations: usize,
};

pub const Message = enum(u8) {
    start_counting,
    end,
};

pub const Context = struct {
    cpu: linux.cpu_set_t,
    sock: i32,
    count_allocs: bool,
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
    const smp_allocator = std.heap.smp;
    const counting_allocator = CountAllocator{};

    const allocator = if (ctx.count_allocs)
        counting_allocator.allocator()
    else
        smp_allocator;

    const threaded = std.Io.Threaded.init(smp_allocator, .{});
    defer threaded.deinit();

    const io = threaded.io();

    try linux.sched_setaffinity(0, &ctx.cpu);

    var serv: kvs.Server = undefined;
    serv.init(allocator, io, .{}) catch |err| return switch (err) {
        error.OutOfMemory => lib.logErr("out of memory initializing server\n", .{}),
    };

    @panic("unimplemented");
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
