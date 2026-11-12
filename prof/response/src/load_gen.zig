const std = @import("std");
const linux = std.os.linux;

const Self = @This();

pub const Context = struct {
    workload: Workload,
    cpu: linux.cpu_set_t,
    sock: i32,
};

pub const Workload = struct {
    operation: Op,
    requests: usize,
    key_count: usize,
    seed: u64,
};

pub const Op = enum(u6) {
    get_hit,
    get_miss,
    set_insert,
    set_replace,
    delete_hit,
    delete_miss,

    fn formatted(self: Op) []const u8 {
        return switch (self) {
            .get_hit => "get-hit",
            .get_miss => "get-miss",
            .set_insert => "set-insert",
            .set_replace => "set-replace",
            .delete_hit => "delete-hit",
            .delete_miss => "delete-miss",
        };
    }
};

pub const Message = enum(u8) {
    ready = 0,
    done = 1,
    start = 2,
    err = 3,
};

pub const ExitCode = enum(u8) {
    success = 0,
    err = 1,

    pub fn value(self: ExitCode) u8 {
        return @intFromEnum(self);
    }
};

pub fn processMain(arg: usize) callconv(.c) u8 {
    _ = arg;
    @panic("unimplemented");
}
