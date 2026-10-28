const std = @import("std");
const linux = std.os.linux;
const Duration = std.Io.Duration;
const Clock = std.Io.Clock;
const errno = linux.errno;

const Self = @This();

sock_fd: i32,
read_timeout: Duration,
write_timeout: Duration,
idle_timeout: Duration,
