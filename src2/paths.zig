//! Filesystem layout: where sockets and persistent state live, plus
//! session-name validation and a tiny glob matcher for `zmx ls foo*`.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

/// Resolve the runtime (socket) directory and create it (mode 0700) if
/// missing. Precedence: $ZMYTH_DIR, $XDG_RUNTIME_DIR/zmyth, /tmp/zmyth-$UID.
/// Caller owns the returned slice.
pub fn runtimeDir(allocator: Allocator) ![]u8 {
    const path = if (posix.getenv("ZMYTH_DIR")) |d|
        try allocator.dupe(u8, d)
    else if (posix.getenv("XDG_RUNTIME_DIR")) |xdg|
        try std.fs.path.join(allocator, &.{ xdg, "zmyth" })
    else
        try std.fmt.allocPrint(allocator, "/tmp/zmyth-{d}", .{posix.getuid()});
    errdefer allocator.free(path);

    try ensureDir(path);
    return path;
}

/// Resolve the state directory and create it if missing.
/// Precedence: $XDG_STATE_HOME/zmyth, ~/.local/state/zmyth.
/// Caller owns the returned slice. Falls back to `<runtimeDir>/state` when
/// $HOME is unset (containers/CI) so the daemon can still log somewhere.
pub fn stateDir(allocator: Allocator) ![]u8 {
    const path = if (posix.getenv("XDG_STATE_HOME")) |xdg|
        try std.fs.path.join(allocator, &.{ xdg, "zmyth" })
    else if (posix.getenv("HOME")) |home|
        try std.fs.path.join(allocator, &.{ home, ".local", "state", "zmyth" })
    else blk: {
        const rt = try runtimeDir(allocator);
        defer allocator.free(rt);
        break :blk try std.fs.path.join(allocator, &.{ rt, "state" });
    };
    errdefer allocator.free(path);

    try ensureDir(path);
    return path;
}

fn ensureDir(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    // The fallback runtime dir lives under shared /tmp. Threat: an attacker
    // pre-creates /tmp/zmyth-<victim-uid> (or a symlink to a dir they can
    // write) so we bind sockets / drop rc shims somewhere they control.
    // Open the leaf as a directory without following symlinks, verify
    // ownership and that it isn't group/other-writable, then tighten perms
    // via the held fd so the check and the chmod hit the same inode.
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len > buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const fd = try posix.openZ(buf[0..path.len :0], .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .NOFOLLOW = true,
    }, 0);
    defer posix.close(fd);
    const st = try posix.fstat(fd);
    if (st.uid != posix.getuid()) return error.RuntimeDirNotOwned;
    if (st.mode & 0o777 != 0o700) {
        posix.fchmod(fd, 0o700) catch |err| switch (err) {
            // Read-only filesystem with already-acceptable ownership: tolerate.
            error.ReadOnlyFileSystem => {},
            else => return err,
        };
    }
}

/// All filesystem paths a session daemon touches, derived from `name`.
/// `sock`/`lock`/`rc_dir`/`env_dir` live under `runtimeDir()`; `log` lives
/// under `stateDir()`. All slices are owned; release with `deinit`.
pub const SessionPaths = struct {
    sock: []u8,
    lock: []u8,
    rc_dir: []u8,
    env_dir: []u8,
    log: []u8,

    pub fn init(allocator: Allocator, name: []const u8) !SessionPaths {
        const rt = try runtimeDir(allocator);
        defer allocator.free(rt);
        const sd = try stateDir(allocator);
        defer allocator.free(sd);

        var self: SessionPaths = undefined;
        self.sock = try std.fmt.allocPrint(allocator, "{s}/{s}.sock", .{ rt, name });
        errdefer allocator.free(self.sock);
        try checkSockLen(self.sock);
        self.lock = try std.fmt.allocPrint(allocator, "{s}/{s}.lock", .{ rt, name });
        errdefer allocator.free(self.lock);
        self.rc_dir = try std.fmt.allocPrint(allocator, "{s}/{s}.rc", .{ rt, name });
        errdefer allocator.free(self.rc_dir);
        self.env_dir = try std.fmt.allocPrint(allocator, "{s}/{s}.env", .{ rt, name });
        errdefer allocator.free(self.env_dir);
        self.log = try std.fmt.allocPrint(allocator, "{s}/{s}.log", .{ sd, name });
        return self;
    }

    pub fn deinit(self: SessionPaths, allocator: Allocator) void {
        allocator.free(self.sock);
        allocator.free(self.lock);
        allocator.free(self.rc_dir);
        allocator.free(self.env_dir);
        allocator.free(self.log);
    }
};

/// "<runtimeDir>/<name>.sock". Caller owns the returned slice. Fails up
/// front with `SocketPathTooLong` if the result would overflow `sun_path`,
/// rather than letting the daemon fork and silently fail to bind.
pub fn socketPath(allocator: Allocator, name: []const u8) ![]u8 {
    const dir = try runtimeDir(allocator);
    defer allocator.free(dir);
    const p = try std.fmt.allocPrint(allocator, "{s}/{s}.sock", .{ dir, name });
    errdefer allocator.free(p);
    try checkSockLen(p);
    return p;
}

/// Unix-domain `sun_path` is tiny (~108 bytes); fail up front rather than
/// letting bind/connect ENAMETOOLONG after the daemon has already forked.
fn checkSockLen(path: []const u8) error{SocketPathTooLong}!void {
    const un_path_len = @typeInfo(@FieldType(std.posix.sockaddr.un, "path")).array.len;
    if (path.len >= un_path_len) return error.SocketPathTooLong;
}

/// Session names become path components and socket filenames; restrict to a
/// safe charset, bounded length, no leading dot (hidden / "." / "..") or
/// leading dash (ambiguous with CLI flags).
pub fn validateName(name: []const u8) error{InvalidName}!void {
    if (name.len == 0 or name.len > 64) return error.InvalidName;
    if (name[0] == '.' or name[0] == '-') return error.InvalidName;
    for (name) |c| {
        const ok = switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '.', '-' => true,
            else => false,
        };
        if (!ok) return error.InvalidName;
    }
}

/// fnmatch-style glob with `*` (any run, including empty) and `?` (exactly
/// one char). No character classes. Iterative two-pointer with backtrack so
/// `*a*b*` doesn't go exponential.
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star_p: ?usize = null; // pattern index just past last '*'
    var star_n: usize = 0; // name index where that '*' started matching

    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == name[n])) {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star_p = p + 1;
            star_n = n;
            p += 1;
        } else if (star_p) |sp| {
            // Backtrack: let the last '*' absorb one more char.
            p = sp;
            star_n += 1;
            n = star_n;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// List session names (basename minus `.sock`) found in the runtime dir.
/// Caller owns the outer slice and each inner string.
pub fn listSessions(allocator: Allocator) ![][]u8 {
    const dir_path = try runtimeDir(allocator);
    defer allocator.free(dir_path);

    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |ent| {
        if (!std.mem.endsWith(u8, ent.name, ".sock")) continue;
        const stem = ent.name[0 .. ent.name.len - ".sock".len];
        if (validateName(stem)) |_| {
            try out.append(allocator, try allocator.dupe(u8, stem));
        } else |_| {}
    }

    std.mem.sort([]u8, out.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    return out.toOwnedSlice(allocator);
}

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "globMatch" {
    // "*" matches anything
    try testing.expect(globMatch("*", ""));
    try testing.expect(globMatch("*", "anything"));

    // "foo*" matches "foobar" not "barfoo"
    try testing.expect(globMatch("foo*", "foobar"));
    try testing.expect(!globMatch("foo*", "barfoo"));

    // "a?c" matches "abc" not "ac"
    try testing.expect(globMatch("a?c", "abc"));
    try testing.expect(!globMatch("a?c", "ac"));

    // "**" same as "*"
    try testing.expect(globMatch("**", ""));
    try testing.expect(globMatch("**", "foobar"));

    // empty pattern matches only empty
    try testing.expect(globMatch("", ""));
    try testing.expect(!globMatch("", "x"));

    // misc
    try testing.expect(globMatch("foo", "foo"));
    try testing.expect(!globMatch("foo", "fo"));
    try testing.expect(globMatch("*.sock", "dev.sock"));
    try testing.expect(globMatch("a*b*c", "axxbxxc"));
    try testing.expect(!globMatch("a*b*c", "axxbxx"));
    try testing.expect(globMatch("?", "x"));
    try testing.expect(!globMatch("?", ""));
}

test "validateName" {
    try validateName("dev");
    try validateName("a_1.2-3");

    try testing.expectError(error.InvalidName, validateName(""));
    try testing.expectError(error.InvalidName, validateName(".foo"));
    try testing.expectError(error.InvalidName, validateName("-foo"));
    try testing.expectError(error.InvalidName, validateName("a/b"));
    try testing.expectError(error.InvalidName, validateName("a b"));
    try testing.expectError(error.InvalidName, validateName("a" ** 65));

    // boundary: 64 chars ok
    try validateName("a" ** 64);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "runtimeDir honours ZMYTH_DIR and creates 0700" {
    const alloc = testing.allocator;
    const tmp = "/tmp/zmyth-paths-test";

    // Clean slate.
    std.fs.deleteTreeAbsolute(tmp) catch {};
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    _ = setenv("ZMYTH_DIR", tmp, 1);
    defer _ = unsetenv("ZMYTH_DIR");

    const dir = try runtimeDir(alloc);
    defer alloc.free(dir);

    try testing.expectEqualStrings(tmp, dir);

    const st = try posix.fstatat(posix.AT.FDCWD, tmp, 0);
    try testing.expect(posix.S.ISDIR(st.mode));
    try testing.expectEqual(@as(u32, 0o700), @as(u32, st.mode) & 0o777);
}

test "socketPath and listSessions" {
    const alloc = testing.allocator;
    const tmp = "/tmp/zmyth-paths-test-ls";

    std.fs.deleteTreeAbsolute(tmp) catch {};
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    _ = setenv("ZMYTH_DIR", tmp, 1);
    defer _ = unsetenv("ZMYTH_DIR");

    const sp = try socketPath(alloc, "dev");
    defer alloc.free(sp);
    try testing.expectEqualStrings(tmp ++ "/dev.sock", sp);

    // Populate fake sockets + noise.
    var d = try std.fs.openDirAbsolute(tmp, .{});
    defer d.close();
    (try d.createFile("dev.sock", .{})).close();
    (try d.createFile("build-1.sock", .{})).close();
    (try d.createFile("noise.txt", .{})).close();

    const sessions = try listSessions(alloc);
    defer {
        for (sessions) |s| alloc.free(s);
        alloc.free(sessions);
    }
    try testing.expectEqual(@as(usize, 2), sessions.len);
    try testing.expectEqualStrings("build-1", sessions[0]);
    try testing.expectEqualStrings("dev", sessions[1]);
}
