const std = @import("std");

const kvs = @import("kvs");

const Cli = @import("Cli.zig");
const runner = @import("runner.zig");

pub fn main(init: std.process.Init) !void {
    var cli: Cli = undefined;
    cli.init(init.io);

    var args = init.minimal.args.iterate();
    const maybe_cmd = try cli.run(init.arena, &args);

    if (maybe_cmd) |cmd| switch (cmd) {
        .run => |inner| try runner.run(init.io, init.arena, inner, .{}),
    };
}
