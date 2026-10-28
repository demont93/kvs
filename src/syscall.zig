const std = @import("std");
const linux = std.os.linux;
const debug = std.debug;

pub fn unexpected_err(syscall_name: []const u8, e: linux.E) noreturn {
    debug.panic("unexpected error on {s} call: {}\n", .{ syscall_name, e });
}

pub fn log_err(syscall_name: []const u8, e: linux.E) void {
    debug.print("unexpected error on {s} call: {}\n", .{ syscall_name, e });
}
