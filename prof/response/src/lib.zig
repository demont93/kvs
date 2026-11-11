const std = @import("std");
const linux = std.os.linux;
const errno = linux.errno;

pub const Err = error{Err};

pub const RwError = error{
    ClosedByPeer,
    Unexpected,
};

pub const ReadAllError = error{
    UnexpectedEof,
} || RwError;

pub fn recvAll(fd: i32, buf: []u8) ReadAllError!void {
    var n_read: usize = 0;
    while (n_read < buf.len) {
        const read_rc = linux.read(fd, buf[n_read..].ptr, buf.len - n_read);
        const n = try switch (errno(read_rc)) {
            .SUCCESS => if (read_rc == 0) ReadAllError.UnexpectedEof else read_rc,
            .INTR => continue,
            .PIPE, .CONNRESET => error.ClosedByPeer,
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

pub fn sendAll(fd: i32, buf: []const u8) RwError!void {
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
            .CONNRESET, .PIPE => error.ClosedByPeer,
            else => |e| errnoUnexpected("write", e),
        };

        n_written += n;
    }
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

pub fn errnoBug(call: []const u8, e: linux.E) noreturn {
    std.debug.panic("errno bug when calling {s}: {t}\n", .{ call, e });
}

pub fn errnoUnexpected(call: []const u8, e: linux.E) error{Unexpected} {
    std.debug.print("unexpected errno when calling {s}: {t}\n", .{ call, e });
    return error.Unexpected;
}

pub fn logErr(comptime fmt: []const u8, args: anytype) Err {
    std.debug.print(fmt, args);
    return Err.Err;
}
