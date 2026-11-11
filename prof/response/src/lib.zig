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
