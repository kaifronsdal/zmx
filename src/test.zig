comptime {
    // Library tests run via the `zmyth` module's own test step; here we
    // reference everything binary-side so `zig build test` covers both.
    _ = @import("zmyth");
    _ = @import("ipc.zig");
    _ = @import("spawn.zig");
    _ = @import("daemon.zig");
    _ = @import("client.zig");
    _ = @import("posix/paths.zig");
    _ = @import("posix/compat.zig");
}
