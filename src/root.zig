//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const Client = @import("Client.zig");
pub const Server = @import("Server.zig");

test {
    _ = @import("protocol.zig");
    _ = @import("Server.zig");
    _ = @import("Client.zig");
    _ = @import("syscall.zig");
}
