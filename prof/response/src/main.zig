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
        .run => |cli_args| {
            const parsed = runner.Run{
                .cpu1 = cli_args.cpu1,
                .cpu2 = cli_args.cpu2,
                .key_count = cli_args.@"key-count",
                .ops = cli_args.ops,
                .port = cli_args.port,
                .requests = cli_args.requests,
                .seed = cli_args.seed,
            };

            try runner.run(init.io, init.gpa, init.arena, parsed);
        },
    };
}

test {
    _ = @import("runner.zig");
    _ = @import("Cli.zig");
    _ = @import("srv.zig");
    _ = @import("LoadGen.zig");
    std.testing.refAllDecls(@This());
}
