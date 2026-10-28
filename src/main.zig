const std = @import("std");
const Io = std.Io;

const kvs = @import("kvs");

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch |e| {
        std.debug.print("failed to init args: {s}", .{@errorName(e)});
        return;
    };

    if (args.len != 2) {
        std.debug.print("requires 1 parameter, got {}", .{args.len});
        return;
    }

    var server: kvs.Server = undefined;
    try server.init(init.gpa, init.io, .{});
    server.listen_and_serve(args[1]);
}
