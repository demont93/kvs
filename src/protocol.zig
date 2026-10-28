const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const enums = std.enums;
const heap = std.heap;
const Allocator = mem.Allocator;
const math = std.math;
const debug = std.debug;

const max_key_size = 64 * 1024;
const max_value_size = 16 * 1024 * 1024;
const parser_buf_size = 1024;

pub const Op = enum(u8) {
    get = 0,
    set = 1,
    del = 2,
};

pub const Request = struct {
    buf: ?[]u8 = null,
    sep: u32 = 0,
    op: Op = .get,

    // Assumes request is full.
    pub fn key(self: *Request) []u8 {
        return self.buf.?[0..self.sep];
    }

    // Assumes request is full.
    pub fn value(self: *Request) []u8 {
        return self.buf.?[self.sep..];
    }
};

pub const ParseError = error{
    InvalidRequest,
    UnexpectedBytes,
    OutOfMemory,
    RequestBufInitialized,
    EmptyRequest,
};

pub const Parser = struct {
    frame_buf: [@sizeOf(u32) * 2 + 1]u8 = undefined,
    frame_index: u32 = 0,
    body_index: u32 = 0,

    pub fn bytes_required(self: *Parser) usize {
        if (self.frame_index < self.frame_buf.len) {
            return self.frame_buf.len - self.frame_index;
        }
        return self.body_length() - self.body_index;
    }

    // Fill a supplied uninitialized Request as bytes are provided. Returns
    // true when the request is initialized. The request buffer is allocated
    // lazily.
    pub fn parse(
        self: *Parser,
        alloc: Allocator,
        chunk: []const u8,
        req: *Request,
    ) ParseError!bool {
        if (chunk.len > self.bytes_required()) {
            return ParseError.UnexpectedBytes;
        }

        if (chunk.len == 0) {
            return ParseError.EmptyRequest;
        }

        if ((self.frame_index < self.frame_buf.len or self.body_index == 0) and
            req.buf != null)
        {
            return ParseError.RequestBufInitialized;
        }

        if (self.frame_index < self.frame_buf.len) {
            try self.parse_frame(chunk);
            return false;
        } else {
            return self.parse_body(alloc, chunk, req);
        }
    }

    fn parse_body(
        self: *Parser,
        alloc: Allocator,
        chunk: []const u8,
        req: *Request,
    ) ParseError!bool {
        var chunk_index: usize = 0;
        // At this point the frame is already parsed and cant return an invalid op.
        const bl, const kl, const op = self.get_frame() catch unreachable;

        if (req.buf == null) {
            req.buf = try alloc.alloc(u8, bl);
        }
        var req_buf = &req.buf.?;

        var body_index = self.body_index;
        const min = @min(chunk.len, req_buf.len - body_index);

        for (0..min) |_| {
            req_buf.*[body_index] = chunk[chunk_index];
            chunk_index += 1;
            body_index += 1;
        }
        self.body_index = body_index;
        if (self.body_index != req_buf.len) {
            return false;
        }

        self.reset();

        req.op = op;
        req.sep = kl;

        return true;
    }

    fn parse_frame(self: *Parser, chunk: []const u8) ParseError!void {
        var chunk_index: usize = 0;
        var frame_index = self.frame_index;

        const min = @min(chunk.len, self.frame_buf.len - frame_index);

        for (0..min) |_| {
            self.frame_buf[frame_index] = chunk[chunk_index];
            frame_index += 1;
            chunk_index += 1;
        }
        self.frame_index = frame_index;

        if (self.frame_index < self.frame_buf.len) {
            return;
        }

        const bl, const kl, const op = self.get_frame() catch |err| switch (err) {
            error.InvalidOp => {
                self.reset();
                return error.InvalidRequest;
            },
        };

        if (kl > bl or
            kl > max_key_size or
            bl - kl > max_value_size or
            kl == 0 or
            ((op == Op.get or op == Op.del) and kl != bl))
        {
            self.reset();
            return error.InvalidRequest;
        }
    }

    pub fn reset(self: *Parser) void {
        self.body_index = 0;
        self.frame_index = 0;
    }

    inline fn get_frame(self: *Parser) error{InvalidOp}!struct { u32, u32, Op } {
        const size_u32 = @sizeOf(u32);
        const bl = mem.readInt(u32, self.frame_buf[0..size_u32], .big);
        const kl = mem.readInt(u32, self.frame_buf[size_u32 .. size_u32 * 2], .big);
        const op = enums.fromInt(
            Op,
            self.frame_buf[self.frame_buf.len - 1],
        ) orelse return error.InvalidOp;
        return .{ bl, kl, op };
    }

    // Returns the body length from the frame buffer which is assumed to be full.
    inline fn body_length(self: *Parser) u32 {
        return mem.readInt(u32, self.frame_buf[0..@sizeOf(u32)], .big);
    }
};

pub const encode = struct {
    pub const ResponseCode = enum(u8) {
        Ok = 0,
        NotFound = 1,
        Invalid = 2,
        Timeout = 3,
        Internal = 4,
    };

    pub const not_found = &[_]u8{ @intFromEnum(ResponseCode.NotFound), 0, 0, 0, 0 };
    pub const invalid = &[_]u8{ @intFromEnum(ResponseCode.Invalid), 0, 0, 0, 0 };
    pub const timeout = &[_]u8{ @intFromEnum(ResponseCode.Timeout), 0, 0, 0, 0 };
    pub const ok = &[_]u8{ @intFromEnum(ResponseCode.Ok), 0, 0, 0, 0 };
    pub const internal = &[_]u8{ @intFromEnum(ResponseCode.Internal), 0, 0, 0, 0 };

    pub fn value(allocator: Allocator, v: []const u8) error{OutOfMemory}![]u8 {
        return encode_msg(allocator, .Ok, v);
    }

    pub fn encode_msg(
        allocator: Allocator,
        code: ResponseCode,
        v: []const u8,
    ) error{OutOfMemory}![]u8 {
        std.debug.assert(switch (code) {
            .Ok => true,
            .NotFound, .Invalid, .Timeout, .Internal => v.len == 0,
        });

        if (v.len > max_value_size) {
            debug.panic("value {} is larger than max {}", .{ v.len, max_value_size });
        }

        const response_size = @sizeOf(u8) + @sizeOf(u32) + v.len;
        var msg = try allocator.alloc(u8, response_size);
        errdefer allocator.free(msg);

        msg[0] = @intFromEnum(code);

        const value_len: u32 = @intCast(v.len);
        mem.writeInt(u32, msg[1..5], value_len, .big);

        @memcpy(msg[5..], v);

        return msg;
    }
};

const testing = std.testing;
const expectEqual = testing.expectEqual;
const expect = testing.expect;
const expectEqualSlices = testing.expectEqualSlices;

test "full message returns correct request" {
    const alloc = testing.allocator;
    var parser = Parser{};

    try expectEqual(9, parser.bytes_required());

    const msg = (((([_]u8{0} ** 3) ++ [_]u8{5}) ** 2) ++ [_]u8{0}) ++ "hello";
    var req = Request{};
    defer {
        if (req.buf) |req_buf| {
            alloc.free(req_buf);
        }
    }

    try expectEqual(false, try (parser.parse(alloc, msg[0..9], &req)));
    try expect(try (parser.parse(alloc, msg[9..], &req)));

    try expectEqual(req.op, Op.get);
    try expectEqualSlices(u8, "hello", req.key());
    try expectEqualSlices(u8, "", req.value());
}

test "sending extra bytes returns error" {
    var tester = parser_tester{};
    defer tester.free();
    const required = tester.parser.bytes_required();
    const msg = tester.msg(5, 5, .set, "hola ", "como ");
    defer tester.alloc.free(msg);
    const result = tester.parser.parse(
        tester.alloc,
        msg[0 .. required + 1],
        &tester.req,
    );
    try testing.expectError(ParseError.UnexpectedBytes, result);
}

test "sending bytes one by one succeeds" {
    var tester = parser_tester{};
    defer tester.free();

    const msg = tester.msg(20, 20, .del, "key: []const u812345", "");
    defer tester.alloc.free(msg);

    for (msg, 0..) |b, i| {
        const result = try tester.parser.parse(
            tester.alloc,
            &[1]u8{b},
            &tester.req,
        );

        if (i == msg.len - 1) {
            try expect(result);
        } else {
            try expect(!result);
        }
    }

    try expectEqualSlices(u8, "key: []const u812345", tester.req.key());
    try expectEqualSlices(u8, "", tester.req.value());
    try expectEqual(Op.del, tester.req.op);
}

test "invalid request resets parser" {
    var tester = parser_tester{};
    defer tester.free();
    try testing.expectError(
        ParseError.InvalidRequest,
        tester.parser.parse(
            tester.alloc,
            &[_]u8{ 0, 0, 0, 4, 0, 0, 0, 8, 0 },
            &tester.req,
        ),
    );

    const msg = [_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 0, 1 };
    try expect(!try tester.parser.parse(
        tester.alloc,
        msg[0..tester.parser.bytes_required()],
        &tester.req,
    ));
    try expect(try tester.parser.parse(
        tester.alloc,
        msg[msg.len - tester.parser.bytes_required() ..],
        &tester.req,
    ));
}

test "multiple correct requests" {
    var tester = parser_tester{};
    defer tester.free();

    const msg1 = tester.msg(5, 5, .set, "hola ", "");
    defer tester.alloc.free(msg1);

    const msg2 = tester.msg(10, 5, .set, "hola ", "como ");
    defer tester.alloc.free(msg2);

    try expect(try tester.parse_msg(msg1));
    try expectEqualSlices(u8, "", tester.req.value());
    tester.alloc.free(tester.req.buf.?);
    tester.req.buf = null;

    try expect(try tester.parse_msg(msg2));
    try expectEqualSlices(u8, "como ", tester.req.value());
}

test "initial request has allocated buffer error" {
    var tester = parser_tester{};
    defer tester.free();

    const msg1 = tester.msg(5, 5, .set, "hola ", "");

    tester.req.buf = try tester.alloc.alloc(u8, 5);

    defer tester.alloc.free(msg1);

    try testing.expectError(ParseError.RequestBufInitialized, tester.parse_msg(msg1));
}

test "passing an empty chunk or msg gives error" {
    var tester = parser_tester{};
    defer tester.free();

    try testing.expectError(ParseError.EmptyRequest, tester.parser.parse(
        tester.alloc,
        &[0]u8{},
        &tester.req,
    ));
}

const parser_tester = struct {
    const Self = @This();

    alloc: Allocator = testing.allocator,
    parser: Parser = Parser{},
    req: Request = Request{},

    fn parse_msg(self: *Self, buf: []u8) ParseError!bool {
        _ = try self.parser.parse(
            self.alloc,
            buf[0..self.parser.bytes_required()],
            &self.req,
        );
        return self.parser.parse(
            self.alloc,
            buf[buf.len - self.parser.bytes_required() ..],
            &self.req,
        );
    }

    fn free(self: *Self) void {
        if (self.req.buf) |buf| {
            self.alloc.free(buf);
        }
    }

    // msg must be freed.
    fn msg(self: *Self, bl: u32, kl: u32, op: Op, key: []const u8, value: []const u8) []u8 {
        const size = @sizeOf(@TypeOf(bl)) + @sizeOf(@TypeOf(kl)) +
            @sizeOf(@TypeOf(op)) + key.len + value.len;
        const u32s = @sizeOf(u32);
        var buf = self.alloc.alloc(u8, size) catch @panic("failed to allocate");
        mem.writeInt(u32, buf[0..u32s], bl, .big);
        mem.writeInt(u32, buf[u32s .. u32s * 2], kl, .big);
        buf[u32s * 2] = @intFromEnum(op);
        var start: usize = u32s * 2 + 1;
        @memcpy(buf[start .. start + key.len], key);
        start += key.len;
        @memcpy(buf[start..], value);
        return buf;
    }
};
