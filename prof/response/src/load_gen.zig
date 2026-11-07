const std = @import("std");
const linux = std.os.linux;

const Self = @This();

pub fn loadGen(arg: *Context) callconv(.c) u8 {
    _ = arg;
    @panic("unimplemented");
}

const Context = struct {
    workload: Workload,
    cpu: linux.cpu_set_t,
};

const Workload = struct {
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
