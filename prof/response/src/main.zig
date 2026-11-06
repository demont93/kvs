const std = @import("std");

const kvs = @import("kvs");

const Cli = @import("Cli.zig");

pub fn main(init: std.process.Init) !void {
    var cli: Cli = undefined;
    cli.init(init.io);

    var args = init.minimal.args.iterate();
    _ = try cli.run(init.arena, &args);
}
