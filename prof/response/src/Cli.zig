const std = @import("std");
const load_gen = @import("load_gen.zig");
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
const Args = std.process.Args;
const mem = std.mem;
const testing = std.testing;

const Self = @This();

w_buf: [128]u8,
w: Io.File.Writer,
io: Io,

/// Accepts FieldSpec of enum, converting kebab case into snake case.
const CommandSpec = union(enum) {
    run: struct {
        pub const port: FieldSpec(u16) = .{ .short = 'p' };
        pub const cpu1: FieldSpec(i32) = .{ .short = '1' };
        pub const cpu2: FieldSpec(i32) = .{ .short = '2' };
        pub const requests: FieldSpec(u64) = .{ .short = 'r' };
        pub const @"key-count": FieldSpec(u64) = .{ .short = 'k' };
        pub const seed: FieldSpec(u64) = .{ .short = 's' };
        pub const op: FieldSpec(load_gen.Op) = .{ .short = 'o' };

        fn validate(cmd: anytype) !void {
            if (cmd.cpu1 == cmd.cpu2) {
                return error.SameCpu;
            }
        }
    },
};

fn FieldSpec(T: type) type {
    return struct {
        const Child = T;
        default: ?T = null,
        short: ?u8 = null,
    };
}

const CommandType = enum {
    parser,
    output,
};

fn Command(command_type: CommandType) type {
    const UnionField = std.builtin.Type.UnionField;

    var names: []const []const u8 = &.{};
    var ftypes: []const type = &.{};
    var attrs: []const UnionField.Attributes = &.{};

    for (@typeInfo(CommandSpec).@"union".fields) |f| {
        names = names ++ &[_][]const u8{f.name};
        ftypes = ftypes ++ &[_]type{CommandVariant(@FieldType(CommandSpec, f.name), command_type)};
        attrs = attrs ++ &[_]UnionField.Attributes{.{}};
    }

    return @Union(
        .auto,
        std.meta.Tag(CommandSpec),
        names,
        ftypes[0..names.len],
        attrs[0..names.len],
    );
}

fn CommandVariant(T: type, command_type: CommandType) type {
    const StructField = std.builtin.Type.StructField;
    return switch (@typeInfo(T)) {
        .void => void,
        .@"struct" => |tinfo| blk: {
            const decls = tinfo.decls;

            var names: []const []const u8 = &.{};
            var ftypes: []const type = &.{};
            var attrs: []const StructField.Attributes = &.{};

            for (decls) |d| {
                const spec = &@field(T, d.name);
                const FSpec = @TypeOf(spec.*);
                const Field = switch (command_type) {
                    .parser => FieldParser(FSpec, spec),
                    .output => FieldOutput(FSpec),
                };

                names = names ++ &[_][]const u8{d.name};
                ftypes = ftypes ++ &[_]type{Field};
                const default: StructField.Attributes = switch (command_type) {
                    .parser => .{ .default_value_ptr = &Field{} },
                    .output => .{},
                };
                attrs = attrs ++ &[_]StructField.Attributes{default};
            }

            break :blk @Struct(.auto, null, names, ftypes[0..names.len], attrs[0..names.len]);
        },
        else => @compileError(
            "invalid type for command variant: can only be struct or void: " ++
                @typeName(T),
        ),
    };
}

fn FieldParser(FSpec: type, spec_ptr: *const FSpec) type {
    const default = switch (@typeInfo(FSpec.Child)) {
        .optional => null,
        else => undefined,
    };
    return struct {
        const Spec = FSpec;
        const spec = spec_ptr;

        value: Spec.Child = default,
        parsed: bool = false,

        fn result(self: @This()) !Spec.Child {
            switch (@typeInfo(Spec.Child)) {
                .optional => {
                    if (self.value) |v| {
                        return v;
                    }
                    if (spec.default) |v| {
                        return v;
                    }
                    return null;
                },
                else => {
                    if (self.parsed) {
                        return self.value;
                    }
                    if (spec.default) |d| {
                        return d;
                    }
                    return error.MissingFlag;
                },
            }
        }
    };
}

fn FieldOutput(FSpec: type) type {
    return FSpec.Child;
}

pub fn init(self: *Self, io: Io) void {
    self.io = io;
    self.w = .init(.stdout(), io, &self.w_buf);
}

/// command flags args
pub fn run(
    self: *Self,
    arena: *ArenaAllocator,
    args_iterator: *Args.Iterator,
) !?Command(.output) {
    _ = args_iterator.skip();

    const first = args_iterator.next() orelse return error.ExpectedCommand;

    if (mem.eql(u8, first, "-h") or mem.eql(u8, first, "--help")) {
        self.printHelp();
        return null;
    }

    var command_parser = try parseCommand(first);

    while (try parseFlag(arena, &command_parser, args_iterator)) {}

    return try output(command_parser);
}

fn output(command_parser: Command(.parser)) !Command(.output) {
    switch (command_parser) {
        inline else => |*flagset_parser, tag| {
            const flagset_info = @typeInfo(@TypeOf(flagset_parser.*));

            var ret_val = switch (flagset_info) {
                .void => return @unionInit(Command(.output), @tagName(tag), {}),
                else => @unionInit(Command(.output), @tagName(tag), undefined),
            };

            const flagset = &@field(ret_val, @tagName(tag));

            inline for (flagset_info.@"struct".fields) |f| {
                const flag_parser = &@field(flagset_parser, f.name);
                const flag = &@field(flagset, f.name);

                flag.* = try flag_parser.result();
            }

            const FlagsetSpec = @FieldType(CommandSpec, @tagName(tag));

            if (@hasDecl(FlagsetSpec, "validate")) {
                try FlagsetSpec.validate(flagset.*);
            }

            return ret_val;
        },
    }
}

fn parseFlag(
    arena: *ArenaAllocator,
    command_parser: *Command(.parser),
    args: *Args.Iterator,
) !bool {
    const key = args.next() orelse return false;

    if (key.len < 2 or key[0] != '-' or (key[1] != '-' and key.len != 2))
        return error.InvalidFlag;

    const is_long = key[1] == '-';

    switch (command_parser.*) {
        inline else => |*flagset_parser| {
            switch (@TypeOf(flagset_parser.*)) {
                void => return error.UnrecognizedFlag,
                else => {},
            }

            const FlagsetParser = @TypeOf(flagset_parser.*);
            const FlagEnum = std.meta.FieldEnum(FlagsetParser);

            var maybe_flag: ?FlagEnum = null;

            if (is_long) {
                maybe_flag = std.meta.stringToEnum(FlagEnum, key[2..]);
            } else {
                maybe_flag = inline for (comptime std.meta.tags(FlagEnum)) |flag_enum| {
                    const FlagParser = @FieldType(FlagsetParser, @tagName(flag_enum));
                    // const Spec = FlagType.Spec;
                    const spec = FlagParser.spec;
                    if (spec.short) |c| {
                        if (key[1] == c) break flag_enum;
                    }
                } else null;
            }

            const field = maybe_flag orelse return error.UnrecognizedFlag;

            switch (field) {
                inline else => |f| {
                    const flag = &@field(flagset_parser, @tagName(f));

                    if (flag.parsed) {
                        return error.FlagRepeated;
                    }
                    const FlagType = @TypeOf(flag.*).Spec.Child;
                    flag.value = try parseValue(FlagType, arena, args);
                    flag.parsed = true;
                },
            }

            return true;
        },
    }
}

fn parseValue(T: type, arena: *ArenaAllocator, args: *Args.Iterator) !T {
    return switch (@typeInfo(T)) {
        .optional => |o| parseScalar(o.child, arena, args),
        else => parseScalar(T, arena, args),
    };
}

fn parseScalar(T: type, arena: *ArenaAllocator, args: *Args.Iterator) !T {
    switch (T) {
        bool => return true,
        u16, i16, i32, u64 => |U| {
            const val = args.next() orelse return error.ExpectedValue;
            return try std.fmt.parseInt(U, val, 10);
        },
        []u8 => {
            const val = args.next() orelse return error.ExpectedValue;
            return try arena.allocator().dupe(u8, val);
        },
        else => switch (@typeInfo(T)) {
            .@"enum" => {
                const str = args.next() orelse return error.ExpectedValue;
                const clean = try std.mem.replaceOwned(u8, arena.allocator(), str, "-", "_");
                return std.meta.stringToEnum(T, clean) orelse error.InvalidChoice;
            },
            else => @compileError("flag type not supported"),
        },
    }
}

fn parseCommand(arg: []const u8) !Command(.parser) {
    const command = std.meta.stringToEnum(std.meta.Tag(CommandSpec), arg) orelse
        return error.InvalidCommand;

    switch (command) {
        inline else => |tag| {
            const SpecVariantType = @FieldType(CommandSpec, @tagName(tag));
            return switch (SpecVariantType) {
                void => @unionInit(Command(.parser), @tagName(tag), {}),
                else => @unionInit(Command(.parser), @tagName(tag), .{}),
            };
        },
    }
}

fn printHelp(self: *Self) void {
    self.print(
        \\Usage: profile-response <COMMAND | -h | --help> [ FLAGS...]
        \\
        \\  Commands:
        \\
        \\    - run 
        \\        -1, --cpu1      Core to pin the load generator to
        \\        -2, --cpu2      Core to pin the server to
        \\        -k, --key-count Amount of keys to preload kvs with
        \\        -s, --seed      Seed for the prng
        \\        -r, --requests  Amount of requests to send
        \\        -o, --op        Operation: get-hit, get-miss, set-insert,
        \\                          set-replace, delete-hit, delete-miss
        \\
    ,
        .{},
    );
}

fn print(self: *Self, comptime fmt: []const u8, args: anytype) void {
    self.w.interface.print(fmt, args) catch std.debug.panic(
        "error printing: {t}",
        .{self.w.err.?},
    );
}

test "parse run command" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var args = Args{ .vector = &.{ "run\x00", "--cpu1\x00", "2\x00", "-p", "3432" } };
    var it = args.iterate();

    const command_str = it.next();
    try testing.expect(command_str != null);

    var p = try Self.parseCommand(command_str.?);
    try testing.expectEqual(std.meta.Tag(Command(.parser)).run, std.meta.activeTag(p));

    try testing.expect(try Self.parseFlag(&arena, &p, &it));
    try testing.expect(try Self.parseFlag(&arena, &p, &it));
    try testing.expectEqual(2, p.run.cpu1.value);
    try testing.expectEqual(true, p.run.cpu1.parsed);
    try testing.expectEqual(3432, p.run.port.value);
    try testing.expectEqual(true, p.run.port.parsed);
    try testing.expect(!try Self.parseFlag(&arena, &p, &it));
}

test "parse full command" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var cli: Self = undefined;
    cli.init(testing.io);

    var args = Args{ .vector = &.{
        "profile-response",
        "run\x00",
        "--cpu1\x00",
        "2\x00",
        "-p",
        "3432",
        "--cpu2\x00",
        "3",
        "-k",
        "234",
        "-s",
        "234234",
        "-r",
        "1",
        "-o",
        "get-hit",
    } };
    var it = args.iterate();

    const out = try cli.run(&arena, &it) orelse return error.Fail;
    try testing.expectEqual(std.meta.Tag(Command(.output)).run, std.meta.activeTag(out));
    try testing.expectEqual(2, out.run.cpu1);
    try testing.expectEqual(3432, out.run.port);
    try testing.expectEqual(3, out.run.cpu2);
    try testing.expectEqual(234, out.run.@"key-count");
    try testing.expectEqual(234234, out.run.seed);
    try testing.expectEqual(1, out.run.requests);
    try testing.expectEqual(load_gen.Op.get_hit, out.run.op);
}
