const std = @import("std");
const Io = std.Io;
const math = std.math;
const linux = std.os.linux;
const testing = std.testing;
const debug = std.debug;
const errno = linux.errno;
const builtin = @import("builtin");
const Clock = std.Io.Clock;

pub fn unexpected_err(syscall_name: []const u8, e: linux.E) noreturn {
    debug.panic("unexpected error on {s} call: {}\n", .{ syscall_name, e });
}

pub fn log_err(syscall_name: []const u8, e: linux.E) void {
    debug.print("unexpected error on {s} call: {}\n", .{ syscall_name, e });
}

pub const SockBlock = enum {
    Blocking,
    NonBlocking,
};

pub fn socket(mode: SockBlock) usize {
    const sock_type = linux.SOCK.STREAM | @as(u32, switch (mode) {
        .Blocking => 0,
        .NonBlocking => linux.SOCK.NONBLOCK,
    });
    return linux.socket(linux.AF.INET, sock_type, 0);
}

pub fn parse_addr(addr: []const u8) ?linux.sockaddr.in {
    var addr_u: u32 = 0;
    var octet: u32 = 0;
    var i: usize = 0;
    var pos: i32 = 0;
    var is_zero = false;

    for (0..4) |n_octet| {
        octet = 0;
        pos = 0;
        is_zero = false;

        while (i < addr.len and pos < 3 and addr[i] >= '0' and addr[i] <= '9') {
            if (pos == 0 and addr[i] == '0') is_zero = true;
            if (pos == 1 and is_zero) return null;

            octet *= 10;
            octet += addr[i] - '0';

            pos += 1;
            i += 1;
        }
        if (i == addr.len or
            pos == 0 or
            (n_octet == 3 and addr[i] != ':') or
            (n_octet < 3 and addr[i] != '.') or
            octet > math.maxInt(u8))
        {
            return null;
        }

        addr_u <<= 8;
        addr_u |= octet;
        i += 1;
    }

    var port: u32 = 0;
    const port_start = i;
    is_zero = false;
    while (i < addr.len and port <= math.maxInt(u16) and addr[i] >= '0' and addr[i] <= '9') {
        if (i == port_start and addr[i] == '0') is_zero = true;
        if (i == port_start + 1 and is_zero) return null;
        port *= 10;
        port += addr[i] - '0';

        i += 1;
    }
    if (i < addr.len or i == port_start or port > math.maxInt(u16)) {
        return null;
    }

    return switch (builtin.target.cpu.arch.endian()) {
        .big => .{ .addr = addr_u, .port = @truncate(port) },
        .little => .{ .addr = @byteSwap(addr_u), .port = @byteSwap(@as(u16, @truncate(port))) },
    };
}

/// Returns the RC without INTR, which is retried internally.
pub fn poll(io: Io, fds: []linux.pollfd, deadline: Clock.Timestamp) usize {
    while (true) {
        const timeout = timeout_remaining_ms(io, deadline) orelse return 0;
        const poll_rc = linux.poll(fds.ptr, fds.len, timeout);
        switch (linux.errno(poll_rc)) {
            .INTR => continue,
            else => return poll_rc,
        }
    }
}

pub fn pollfd(fd: i32, events: i16) linux.pollfd {
    return .{.events = events, .fd = fd, .revents = 0};
}

fn timeout_remaining_ms(io: Io, deadline: Clock.Timestamp) ?i32 {
    const timeout = deadline.durationFromNow(io).raw.toMilliseconds();
    return if (timeout > 0) @intCast(timeout) else null;
}

test "octet parser" {
    const addr: linux.sockaddr.in = parse_addr("192.168.1.1:8080") orelse .{ .addr = 0, .port = 0 };
    switch (builtin.target.cpu.arch.endian()) {
        .big => {
            try testing.expectEqual(0xc0a80101, addr.addr);
            try testing.expectEqual(0x1f90, addr.port);
        },
        .little => {
            try testing.expectEqual(0x0101a8c0, addr.addr);
            try testing.expectEqual(0x901f, addr.port);
        },
    }
}

test "fuzz the address parse function" {
    try testing.fuzz({}, fuzz_addr_parse_function, .{});
}

fn fuzz_addr_parse_function(context: void, smith: *testing.Smith) !void {
    _ = context;
    var addr_buf: [40]u8 = undefined;

    while (!smith.eos()) {
        const addr = gen_str_addr(smith, &addr_buf);
        const full_addr = gen_full_addr(smith, &addr_buf, addr.len);

        const result = parse_addr(full_addr);
        const resok = if (result) |_| true else false;

        const sep_ix = std.mem.findScalar(u8, full_addr, ':');
        const is_correct_sep = sep_ix != null;

        const port_slice = if (sep_ix) |i| full_addr[i + 1 ..] else null;

        const port_has_no_leading_zero = if (sep_ix) |i|
            full_addr.len < i + 3 or full_addr[i + 1] != '0'
        else
            true;

        const port_parse_is_ok = if (port_slice) |s|
            if (std.fmt.parseUnsigned(u16, s, 10)) |_| true else |_| false
        else
            false;

        const port_is_ascii = if (port_slice) |s| for (s) |c| {
            if (c < '0' or c > '9') break false;
        } else blk: {
            break :blk true;
        } else false;

        const has_port = if (port_slice) |s| s.len > 0 else false;

        const std_addr = if (sep_ix) |i| full_addr[0..i] else full_addr;

        const std_result = Io.net.Ip4Address.parse(std_addr, 0);

        const stdok = if (std_result) |_| true else |_| false;

        errdefer debug.print(
            \\
            \\Address: |{s}|,
            \\Address s: |{x}|,
            \\
            \\stdok: {},
            \\is_correct_sep: {},
            \\port_is_ascii: {},
            \\port_has_no_leading_zero: {},
            \\post_parse_is_ok: {},
            \\has_port: {},
            \\
            \\resok: {},
            \\
        ,
            .{
                full_addr,
                full_addr,
                stdok,
                is_correct_sep,
                port_is_ascii,
                port_has_no_leading_zero,
                port_parse_is_ok,
                has_port,
                resok,
            },
        );

        try testing.expectEqual(
            stdok and is_correct_sep and port_is_ascii and port_has_no_leading_zero and port_parse_is_ok and has_port,
            resok,
        );
        if (std_result) |stdres| {
            if (result) |res| {
                const stdresu32addr = std.mem.readInt(u32, &stdres.bytes, .big);
                try testing.expectEqual(@byteSwap(stdresu32addr), res.addr);
            }
        } else |_| {}
    }
}

fn gen_full_addr(s: *testing.Smith, addr_buf: *[40]u8, addr_len: usize) []u8 {
    addr_buf[addr_len] = s.valueWeighted(u8, &[_]testing.Smith.Weight{
        .rangeLessThan(u8, 0, ':', 1),
        .value(u8, ':', 254 * 9),
        .rangeAtMost(u8, ':' + 1, 255, 1),
    });
    const port_buf = addr_buf[addr_len + 1 .. addr_len + 1 + 6];
    const port_len = s.sliceWeightedBytes(port_buf, &[_]testing.Smith.Weight{
        .rangeLessThan(u8, 0, '9', 1),
        .rangeAtMost(u8, '0', '9', 72),
        .rangeAtMost(u8, '9' + 1, 255, 1),
    });
    return addr_buf[0 .. addr_len + 1 + port_len];
}

fn gen_str_addr(s: *testing.Smith, addr_buf: *[40]u8) []u8 {
    const n_octets = s.valueRangeAtMost(u32, 0, 5);
    var addr_index: usize = 0;
    for (0..n_octets) |i| {
        if (i != 0) {
            addr_buf[addr_index] = s.valueWeighted(u8, &[_]testing.Smith.Weight{
                .rangeLessThan(u8, 0, '.', 1),
                .value(u8, '.', 254 * 9),
                .rangeAtMost(u8, '.' + 1, 255, 1),
            });
            addr_index += 1;
        }
        const byte_len = gen_str_byte(s, addr_buf[addr_index .. addr_index + 5]);
        addr_index += byte_len;
    }

    return addr_buf[0..addr_index];
}

fn gen_str_byte(s: *testing.Smith, buf: []u8) usize {
    return s.sliceWeightedBytes(buf, &[_]testing.Smith.Weight{
        .rangeLessThan(u8, 0, '0', 1),
        .rangeAtMost(u8, '0', '9', 254 * 9),
        .rangeAtMost(u8, '9' + 1, 255, 1),
    });
}
