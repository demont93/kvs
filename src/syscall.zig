const std = @import("std");
const linux = std.os.linux;
const debug = std.debug;
const errno = linux.errno;

pub fn unexpected_err(syscall_name: []const u8, e: linux.E) noreturn {
    debug.panic("unexpected error on {s} call: {}\n", .{ syscall_name, e });
}

pub fn log_err(syscall_name: []const u8, e: linux.E) void {
    debug.print("unexpected error on {s} call: {}\n", .{ syscall_name, e });
}

pub const SockBlock = enum {
    Blocking,
    NonBlocking,
};

pub fn socket(mode: SockBlock) usize {
    const sock_type = linux.SOCK.STREAM | @as(u32, switch (mode) {
        .Blocking => 0,
        .NonBlocking => linux.SOCK.NONBLOCK,
    });
    return linux.socket(linux.AF.INET, sock_type, 0);
}
