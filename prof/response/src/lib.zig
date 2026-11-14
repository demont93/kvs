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

pub fn clone(arg: ?*anyopaque, f: *const fn (usize) callconv(.c) u8) Err!i32 {
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
        else => |e| errnoUnexpectedErr("clone", e),
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
        else => |e| errnoUnexpectedErr("mmap", e),
    };
}

fn destroyStack(stack: []u8) void {
    switch (errno(linux.munmap(stack.ptr, stack.len))) {
        .SUCCESS => {},
        else => |e| errnoBug("munmap", e),
    }
}

pub fn socketPair() Err![2]i32 {
    var socks: [2]i32 = undefined;

    try switch (errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        &socks,
    ))) {
        .SUCCESS => {},
        .OPNOTSUPP,
        .PROTONOSUPPORT,
        .AFNOSUPPORT,
        => |e| errnoBug("socketpair", e),
        else => |e| errnoUnexpectedErr("socketpair", e),
    };

    return socks;
}

pub fn cloexec(fd: i32) Err!void {
    var flags: usize = @intCast(try getFdFlags(fd));
    flags |= @as(usize, linux.FD_CLOEXEC);
    return switch (errno(linux.fcntl(fd, linux.F.SETFD, flags))) {
        .SUCCESS => {},
        .BADF, .FAULT, .INVAL => |e| errnoBug("fcntl", e),
        else => |e| errnoUnexpectedErr("fcntl", e),
    };
}

pub fn noCloexec(fd: i32) Err!void {
    var flags: usize = @intCast(try getFdFlags(fd));
    flags &= ~@as(usize, linux.FD_CLOEXEC);
    return switch (errno(linux.fcntl(fd, linux.F.SETFD, flags))) {
        .SUCCESS => {},
        .BADF, .FAULT, .INVAL => |e| errnoBug("fcntl", e),
        else => |e| errnoUnexpectedErr("fcntl", e),
    };
}

fn getFdFlags(fd: i32) Err!i32 {
    const f_rc = linux.fcntl(fd, linux.F.GETFD, 0);
    return switch (errno(f_rc)) {
        .SUCCESS => @as(i32, @intCast(f_rc)),
        .BADF, .FAULT, .INVAL => |e| errnoBug("fcntl", e),
        else => |e| errnoUnexpectedErr("fcntl", e),
    };
}

pub fn closeFd(fd: i32) Err!void {
    return switch (errno(linux.close(fd))) {
        .SUCCESS => {},
        .INTR, .IO => |e| logErr("close failed: {t}\n", .{e}),
        .BADF => |e| errnoBug("close", e),
        else => |e| errnoUnexpectedErr("close", e),
    };
}

pub fn closeFdLog(fd: i32) void {
    closeFd(fd) catch {};
}

pub fn waitChild(pid: i32) Err!u8 {
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

pub fn killChild(pid: i32) void {
    switch (errno(linux.kill(pid, linux.SIG.KILL))) {
        .SUCCESS => {},
        .SRCH => |e| errnoUnexpected("kill", e) catch {},
        else => |e| errnoBug("kill", e),
    }

    var status: u32 = undefined;

    switch (errno(linux.waitpid(pid, &status, 0))) {
        .SUCCESS => {},
        else => |e| errnoBug("waitpid", e),
    }
}

pub fn errnoBug(call: []const u8, e: linux.E) noreturn {
    std.debug.panic("errno bug when calling {s}: {t}\n", .{ call, e });
}

pub fn errnoUnexpected(call: []const u8, e: linux.E) error{Unexpected} {
    std.debug.print("unexpected errno when calling {s}: {t}\n", .{ call, e });
    return error.Unexpected;
}

pub fn errnoUnexpectedErr(call: []const u8, e: linux.E) Err {
    std.debug.print("unexpected errno when calling {s}: {t}\n", .{ call, e });
    return Err.Err;
}

pub fn logErr(comptime fmt: []const u8, args: anytype) Err {
    std.debug.print(fmt, args);
    return Err.Err;
}
