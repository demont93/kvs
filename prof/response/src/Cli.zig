const std = @import("std");
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
const Args = std.process.Args;
const mem = std.mem;
const testing = std.testing;

const Self = @This();

w_buf: [128]u8,
w: Io.File.Writer,
io: Io,

const CommandSpec = union(enum) {
    run: struct {
        pub const port: FieldSpec(i16) = .{ .short = 'p' };
        pub const cpu1: FieldSpec(i32) = .{};
        pub const cpu2: FieldSpec(i32) = .{};

        fn validate(cmd: anytype) !void {
            if (cmd.cpu1 == cmd.cpu2) {
                return error.SameCpu;
            }
        }
    },
    restore,
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

fn init(self: *Self, io: Io) void {
    self.io = io;
    self.w = .init(.stdout(), io, &self.w_buf);
}

/// command flags args
fn run(
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
        i16, i32 => |U| {
            const val = args.next() orelse return error.ExpectedValue;
            return try std.fmt.parseInt(U, val, 10);
        },
        []u8 => {
            const val = args.next() orelse return error.ExpectedValue;
            return try arena.allocator().dupe(u8, val);
        },
        else => @compileError("only bool, i32 and []u8 supported for flags"),
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
        \\    - run --cpu1 <n> --cpu2 <n> --port <n>
        \\        Sets up the environment and runs the profiling. 
        \\
        \\    - restore
        \\        Restores initial state from the last saved state file.
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
    } };
    var it = args.iterate();

    const out = try cli.run(&arena, &it) orelse return error.Fail;
    try testing.expectEqual(std.meta.Tag(Command(.output)).run, std.meta.activeTag(out));
    try testing.expectEqual(2, out.run.cpu1);
    try testing.expectEqual(3432, out.run.port);
    try testing.expectEqual(3, out.run.cpu2);
}
