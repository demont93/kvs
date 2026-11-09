const std = @import("std");
const linux = std.os.linux;

const Self = @This();

pub const Context = struct {
    workload: Workload,
    cpu: linux.cpu_set_t,
};

pub const Workload = struct {
    operation: Op,
    requests: usize,
    key_count: usize,
    seed: u64,
};

pub const Op = enum {
    get_hit,
    get_miss,
    set_insert,
    set_replace,
    delete_hit,
    delete_miss,
};

pub const Message = enum(u8) {
    ready = 0,
    done = 1,
    start = 2,
    err = 3,
};

pub const ExitCode = enum(u8) {
    success = 0,
};

pub fn processMain(arg: usize) callconv(.c) u8 {
    _ = arg;
    @panic("unimplemented");
}
