//! IPC framing over a Unix stream socket.
//!
//! Wire: 8-byte Header `{tag: u8, _pad: [3]u8, len: u32}` + `len` bytes of
//! payload. The payload encoding is derived at comptime from the `Msg`
//! union — there is no per-tag hand-packing. Adding a field to a message
//! is a one-line edit to its struct; encode/decode update automatically.
//!
//! Field encoding within a struct arm: each non-slice field is emitted as
//! its raw native bytes (`@sizeOf(T)` each, no padding between), in
//! declaration order; at most one `[]const u8` field is allowed and it
//! occupies the tail. Same-arch on both ends (same binary), so endianness
//! and layout are non-issues.
//!
//! The first frame on every connection is `.hello{proto_version}`. A
//! mismatch closes the connection with a clear error — simpler than
//! per-field forward-compat for the rare "old daemon, new client" case.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

pub const Via = @import("zmyth").Via;

/// Bumped on any wire-incompatible change to `Msg`.
pub const proto_version: u32 = 1;

/// Sentinel for "exit code unknown" in `.run_done` (i32 can't be optional
/// on the wire).
pub const null_exit: i32 = std.math.minInt(i32);

/// Maximum payload size accepted on the read path.
const max_frame_len: u32 = 16 * 1024 * 1024;

/// Wire values are frozen. Add new tags at the end with the next free
/// value; never reuse a removed one. With the `.hello` version gate,
/// reordering would only break the same-binary case anyway, but explicit
/// values keep `git blame` honest.
pub const Tag = enum(u8) {
    // ── client → daemon ──────────────────────────────────────────────────
    attach = 0,
    input = 1,
    resize = 2,
    run = 3,
    send = 4,
    read = 5,
    write_hdr = 6,
    write_begin = 7,
    write_data = 8,
    info = 9,
    wait = 10,
    kill = 11,
    detach = 12,
    hook = 13,
    // ── daemon → client ──────────────────────────────────────────────────
    output = 14,
    state = 15,
    run_done = 16,
    info_reply = 17,
    data = 18,
    ack = 19,
    err = 20,
    eof = 21,
    // ── handshake ────────────────────────────────────────────────────────
    hello = 22,
};

/// One IPC message. The schema *is* this union: encode/decode walk it at
/// comptime, so the wire format follows from field declaration order.
///
/// Arm shapes:
///   `[]const u8`  — payload is the raw bytes (bulk; zero envelope)
///   `void`        — empty payload
///   struct        — fixed fields packed, then ≤1 `[]const u8` tail
///
/// Slices in a decoded `Msg` borrow the framer's read buffer (or the
/// `recvBlocking` scratch buffer) and are valid until the next read.
pub const Msg = union(Tag) {
    // c→d
    attach: struct { cols: u16, rows: u16, env: []const u8 },
    input: []const u8,
    resize: struct { cols: u16, rows: u16 },
    run: struct { interactive: bool, cmd: []const u8 },
    send: []const u8,
    read: struct { mode: u8, tail_n: u32 },
    write_hdr: struct { path: []const u8 },
    write_begin: struct { mode: u8, enc_len: u64 },
    write_data: []const u8,
    info: void,
    wait: void,
    kill: struct { sig: u8 },
    detach: void,
    hook: void,
    // d→c
    output: []const u8,
    state: []const u8,
    run_done: RunDone,
    info_reply: []const u8,
    data: []const u8,
    ack: []const u8,
    err: []const u8,
    eof: void,
    // handshake
    hello: struct { ver: u32 },

    pub const RunDone = struct {
        /// `null_exit` encodes "unknown".
        exit_code: i32,
        via: Via,
        dur_ms: u64,

        pub fn ec(self: RunDone) ?i32 {
            return if (self.exit_code == null_exit) null else self.exit_code;
        }
    };

    pub fn tag(self: Msg) Tag {
        return std.meta.activeTag(self);
    }
};

const Header = extern struct {
    tag: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
    /// Native (little) endian; daemon and client are the same binary.
    len: u32,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 8);
}

// ─────────────────────── comptime codec ───────────────────────

fn isSlice(comptime T: type) bool {
    return @typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice;
}

/// Sum of `@sizeOf` for non-slice fields. Comptime-asserts at most one
/// slice field and that it's declared last.
fn fixedSize(comptime S: type) usize {
    var sz: usize = 0;
    var seen_slice = false;
    for (@typeInfo(S).@"struct".fields) |f| {
        if (isSlice(f.type)) {
            if (seen_slice) @compileError(@typeName(S) ++ ": >1 slice field");
            seen_slice = true;
        } else {
            if (seen_slice) @compileError(@typeName(S) ++ ": field after slice");
            sz += @sizeOf(f.type);
        }
    }
    return sz;
}

fn payloadLen(msg: Msg) usize {
    return switch (msg) {
        inline else => |v, t| switch (@TypeOf(v)) {
            void => 0,
            []const u8 => v.len,
            else => blk: {
                var n = comptime fixedSize(@TypeOf(v));
                inline for (@typeInfo(@TypeOf(v)).@"struct".fields) |f| {
                    if (comptime isSlice(f.type)) n += @field(v, f.name).len;
                }
                _ = t;
                break :blk n;
            },
        },
    };
}

/// Write `msg`'s payload into `buf` (length = `payloadLen(msg)`).
fn encodeInto(msg: Msg, buf: []u8) void {
    switch (msg) {
        inline else => |v| switch (@TypeOf(v)) {
            void => {},
            []const u8 => @memcpy(buf, v),
            else => {
                var off: usize = 0;
                inline for (@typeInfo(@TypeOf(v)).@"struct".fields) |f| {
                    const fv = @field(v, f.name);
                    if (comptime isSlice(f.type)) {
                        @memcpy(buf[off..][0..fv.len], fv);
                        off += fv.len;
                    } else {
                        @memcpy(buf[off..][0..@sizeOf(f.type)], std.mem.asBytes(&fv));
                        off += @sizeOf(f.type);
                    }
                }
            },
        },
    }
}

pub const DecodeError = error{ UnknownTag, ShortPayload, FrameTooLarge };

/// Decode `payload` as the arm for `tag_byte`. Returned slices alias
/// `payload`.
pub fn decode(tag_byte: u8, payload: []const u8) DecodeError!Msg {
    const t = std.meta.intToEnum(Tag, tag_byte) catch return error.UnknownTag;
    switch (t) {
        inline else => |ct| {
            const A = @FieldType(Msg, @tagName(ct));
            return switch (@typeInfo(A)) {
                .void => @unionInit(Msg, @tagName(ct), {}),
                .pointer => @unionInit(Msg, @tagName(ct), payload),
                .@"struct" => blk: {
                    const fs = comptime fixedSize(A);
                    if (payload.len < fs) return error.ShortPayload;
                    var v: A = undefined;
                    var off: usize = 0;
                    inline for (@typeInfo(A).@"struct".fields) |f| {
                        if (comptime isSlice(f.type)) {
                            @field(v, f.name) = payload[off..];
                        } else {
                            @memcpy(
                                std.mem.asBytes(&@field(v, f.name)),
                                payload[off..][0..@sizeOf(f.type)],
                            );
                            off += @sizeOf(f.type);
                        }
                    }
                    break :blk @unionInit(Msg, @tagName(ct), v);
                },
                else => @compileError("unsupported arm type"),
            };
        },
    }
}

// ─────────────────────── Framer ───────────────────────

pub const Framer = struct {
    gpa: Allocator,

    read_buf: std.ArrayList(u8) = .empty,
    /// Bytes in read_buf[0..read_pos] have been returned by next() and may
    /// be discarded on the next pushRead()/next() call.
    read_pos: usize = 0,

    write_buf: std.ArrayList(u8) = .empty,
    write_pos: usize = 0,

    pub fn init(allocator: Allocator) Framer {
        return .{ .gpa = allocator };
    }

    pub fn deinit(self: *Framer) void {
        self.read_buf.deinit(self.gpa);
        self.write_buf.deinit(self.gpa);
        self.* = undefined;
    }

    fn compactRead(self: *Framer) void {
        if (self.read_pos == 0) return;
        const tail = self.read_buf.items[self.read_pos..];
        std.mem.copyForwards(u8, self.read_buf.items[0..tail.len], tail);
        self.read_buf.items.len = tail.len;
        self.read_pos = 0;
    }

    /// Hand bytes just read from the socket to the framer. Invalidates any
    /// slices in a previously-returned `Msg`.
    pub fn pushRead(self: *Framer, bytes: []const u8) !void {
        self.compactRead();
        try self.read_buf.appendSlice(self.gpa, bytes);
    }

    /// Pop one complete message if available. Slices in the returned `Msg`
    /// borrow read_buf and are valid until the next `pushRead()`/`next()`.
    pub fn next(self: *Framer) DecodeError!?Msg {
        self.compactRead();
        const buf = self.read_buf.items;
        if (buf.len < @sizeOf(Header)) return null;

        var hdr: Header = undefined;
        @memcpy(std.mem.asBytes(&hdr), buf[0..@sizeOf(Header)]);
        if (hdr.len > max_frame_len) return error.FrameTooLarge;

        const total = @sizeOf(Header) + hdr.len;
        if (buf.len < total) return null;

        const payload = buf[@sizeOf(Header)..total];
        self.read_pos = total;
        return try decode(hdr.tag, payload);
    }

    /// Append a frame to the outbound buffer.
    pub fn queue(self: *Framer, msg: Msg) !void {
        const len = payloadLen(msg);
        if (len > max_frame_len) return error.FrameTooLarge;
        const hdr: Header = .{ .tag = @intFromEnum(msg.tag()), .len = @intCast(len) };
        try self.write_buf.ensureUnusedCapacity(self.gpa, @sizeOf(Header) + len);
        self.write_buf.appendSliceAssumeCapacity(std.mem.asBytes(&hdr));
        encodeInto(msg, self.write_buf.addManyAsSliceAssumeCapacity(len));
    }

    pub fn pendingWrite(self: *const Framer) []const u8 {
        return self.write_buf.items[self.write_pos..];
    }

    pub fn hasPendingWrite(self: *const Framer) bool {
        return self.write_pos < self.write_buf.items.len;
    }

    pub fn consumeWrite(self: *Framer, n: usize) void {
        std.debug.assert(self.write_pos + n <= self.write_buf.items.len);
        self.write_pos += n;
        if (self.write_pos == self.write_buf.items.len) {
            self.write_buf.clearRetainingCapacity();
            self.write_pos = 0;
        } else if (self.write_pos > self.write_buf.items.len / 2) {
            const rem = self.write_buf.items.len - self.write_pos;
            std.mem.copyForwards(u8, self.write_buf.items[0..rem], self.write_buf.items[self.write_pos..]);
            self.write_buf.shrinkRetainingCapacity(rem);
            self.write_pos = 0;
        }
    }
};

// ─────────────────── blocking helpers (simple clients) ───────────────────

const writeAll = @import("posix/compat.zig").writeAllFd;

fn readExact(fd: posix.fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try posix.read(fd, buf[off..]);
        if (n == 0) return error.UnexpectedEof;
        off += n;
    }
}

/// Send one message, blocking until fully written.
pub fn sendBlocking(gpa: Allocator, fd: posix.fd_t, msg: Msg) !void {
    const len = payloadLen(msg);
    if (len > max_frame_len) return error.FrameTooLarge;
    const hdr: Header = .{ .tag = @intFromEnum(msg.tag()), .len = @intCast(len) };
    try writeAll(fd, std.mem.asBytes(&hdr));
    if (len <= 256) {
        var buf: [256]u8 = undefined;
        encodeInto(msg, buf[0..len]);
        try writeAll(fd, buf[0..len]);
    } else {
        const buf = try gpa.alloc(u8, len);
        defer gpa.free(buf);
        encodeInto(msg, buf);
        try writeAll(fd, buf);
    }
}

/// Receive one message, blocking. Payload is read into `scratch` (cleared
/// first); slices in the returned `Msg` borrow `scratch` and are valid
/// until the next `recvBlocking` on the same scratch.
pub fn recvBlocking(gpa: Allocator, fd: posix.fd_t, scratch: *std.ArrayList(u8)) !Msg {
    var hdr: Header = undefined;
    try readExact(fd, std.mem.asBytes(&hdr));
    if (hdr.len > max_frame_len) return error.FrameTooLarge;
    scratch.clearRetainingCapacity();
    try scratch.resize(gpa, hdr.len);
    try readExact(fd, scratch.items);
    return decode(hdr.tag, scratch.items);
}

/// Send `.hello{proto_version}`, receive the reply. Returns the daemon's
/// version on mismatch (caller reports + exits), 0 if the peer doesn't
/// speak the handshake at all (pre-hello daemon, or already gone), null on
/// match. Only OOM propagates as an error.
pub fn handshake(gpa: Allocator, fd: posix.fd_t, scratch: *std.ArrayList(u8)) error{OutOfMemory}!?u32 {
    sendBlocking(gpa, fd, .{ .hello = .{ .ver = proto_version } }) catch |e| switch (e) {
        error.OutOfMemory => |oom| return oom,
        else => return 0,
    };
    const reply = recvBlocking(gpa, fd, scratch) catch |e| switch (e) {
        error.OutOfMemory => |oom| return oom,
        else => return 0,
    };
    return switch (reply) {
        .hello => |h| if (h.ver == proto_version) null else h.ver,
        else => 0,
    };
}

// ───────────────────────────── tests ─────────────────────────────

const testing = std.testing;

/// queue → wire → decode → expectEqualDeep against the input. Slices stay
/// valid because src/dst live for the whole comparison.
fn expectRoundTrip(msg: Msg) !void {
    var src = Framer.init(testing.allocator);
    defer src.deinit();
    try src.queue(msg);

    var dst = Framer.init(testing.allocator);
    defer dst.deinit();
    try dst.pushRead(src.pendingWrite());
    const out = (try dst.next()).?;
    try testing.expect((try dst.next()) == null);
    try testing.expectEqual(msg.tag(), out.tag());
    switch (msg) {
        inline else => |v, t| try testing.expectEqualDeep(v, @field(out, @tagName(t))),
    }
}

test "round-trip every Msg arm" {
    // void
    try expectRoundTrip(.info);
    try expectRoundTrip(.eof);
    try expectRoundTrip(.wait);
    try expectRoundTrip(.detach);
    try expectRoundTrip(.hook);
    // bulk
    try expectRoundTrip(.{ .output = "hello" });
    try expectRoundTrip(.{ .write_data = "" });
    try expectRoundTrip(.{ .input = "\x1b[A" });
    // struct: fixed-only
    try expectRoundTrip(.{ .resize = .{ .cols = 120, .rows = 40 } });
    try expectRoundTrip(.{ .hello = .{ .ver = 0xDEADBEEF } });
    try expectRoundTrip(.{ .kill = .{ .sig = 9 } });
    try expectRoundTrip(.{ .run_done = .{ .exit_code = 7, .via = .osc_done, .dur_ms = 1234 } });
    // struct: fixed + tail slice
    try expectRoundTrip(.{ .run = .{ .interactive = true, .cmd = "echo hi" } });
    try expectRoundTrip(.{ .run = .{ .interactive = false, .cmd = "" } });
    try expectRoundTrip(.{ .attach = .{ .cols = 80, .rows = 24, .env = "K=V\x00X=Y\x00" } });
    // struct: slice-only
    try expectRoundTrip(.{ .write_hdr = .{ .path = "/tmp/x" } });
    // struct: u8 + u64 (mixed sizes, no padding)
    try expectRoundTrip(.{ .write_begin = .{ .mode = 'z', .enc_len = 1 << 40 } });
    // struct: u8 + u32
    try expectRoundTrip(.{ .read = .{ .mode = 2, .tail_n = 100 } });
}

test "RunDone.ec(): null_exit ↔ null" {
    try testing.expectEqual(@as(?i32, null), (Msg.RunDone{
        .exit_code = null_exit,
        .via = .line_rejected,
        .dur_ms = 0,
    }).ec());
    try testing.expectEqual(@as(?i32, 7), (Msg.RunDone{
        .exit_code = 7,
        .via = .osc_done,
        .dur_ms = 0,
    }).ec());
}

test "fixedSize: packed, no inter-field padding" {
    // u8 + u64 = 9, not 16 (would be 16 in an extern struct).
    try testing.expectEqual(@as(usize, 9), comptime fixedSize(@FieldType(Msg, "write_begin")));
    // i32 + Via(u8) + u64 = 13.
    try testing.expectEqual(@as(usize, 13), comptime fixedSize(Msg.RunDone));
    // bool + slice = 1.
    try testing.expectEqual(@as(usize, 1), comptime fixedSize(@FieldType(Msg, "run")));
}

test "decode: short payload → error, not garbage" {
    try testing.expectError(error.ShortPayload, decode(@intFromEnum(Tag.resize), "\x00"));
    try testing.expectError(error.ShortPayload, decode(@intFromEnum(Tag.run_done), &[_]u8{0} ** 12));
}

test "decode: unknown tag → error" {
    try testing.expectError(error.UnknownTag, decode(200, ""));
}

test "decode: extra trailing bytes on fixed-only struct are ignored" {
    // Forward-compat for append-only: a new client appends a field; an old
    // daemon (this code) reads the prefix it knows and ignores the tail.
    var buf: [8]u8 = undefined;
    encodeInto(.{ .resize = .{ .cols = 80, .rows = 24 } }, buf[0..4]);
    @memset(buf[4..], 0xFF);
    const m = (try decode(@intFromEnum(Tag.resize), &buf)).resize;
    try testing.expectEqual(@as(u16, 80), m.cols);
    try testing.expectEqual(@as(u16, 24), m.rows);
}

test "Framer: header split across reads" {
    var src = Framer.init(testing.allocator);
    defer src.deinit();
    try src.queue(.{ .ack = "ok" });
    const wire = src.pendingWrite();

    var dst = Framer.init(testing.allocator);
    defer dst.deinit();
    try dst.pushRead(wire[0..5]);
    try testing.expect((try dst.next()) == null);
    try dst.pushRead(wire[5..]);
    try testing.expectEqualStrings("ok", (try dst.next()).?.ack);
    try testing.expect((try dst.next()) == null);
}

test "Framer: payload split at every offset" {
    var src = Framer.init(testing.allocator);
    defer src.deinit();
    try src.queue(.{ .run = .{ .interactive = false, .cmd = "abcdefghij" } });
    const wire = src.pendingWrite();

    var i: usize = 1;
    while (i < wire.len) : (i += 1) {
        var dst = Framer.init(testing.allocator);
        defer dst.deinit();
        try dst.pushRead(wire[0..i]);
        try testing.expect((try dst.next()) == null);
        try dst.pushRead(wire[i..]);
        const m = (try dst.next()).?.run;
        try testing.expect(!m.interactive);
        try testing.expectEqualStrings("abcdefghij", m.cmd);
    }
}

test "Framer: three frames coalesced" {
    var src = Framer.init(testing.allocator);
    defer src.deinit();
    try src.queue(.{ .state = "A" });
    try src.queue(.eof);
    try src.queue(.{ .err = "BB" });

    var dst = Framer.init(testing.allocator);
    defer dst.deinit();
    try dst.pushRead(src.pendingWrite());
    try testing.expectEqualStrings("A", (try dst.next()).?.state);
    try testing.expectEqual(Msg.eof, (try dst.next()).?.tag());
    try testing.expectEqualStrings("BB", (try dst.next()).?.err);
    try testing.expect((try dst.next()) == null);
}

test "Framer: consumeWrite partial + reset" {
    var f = Framer.init(testing.allocator);
    defer f.deinit();
    try f.queue(.{ .ack = "xyz" });
    const total = @sizeOf(Header) + 3;
    f.consumeWrite(3);
    try testing.expectEqual(total - 3, f.pendingWrite().len);
    f.consumeWrite(total - 3);
    try testing.expect(!f.hasPendingWrite());
    try f.queue(.eof);
    try testing.expectEqual(@as(usize, @sizeOf(Header)), f.pendingWrite().len);
}

test "Framer: FrameTooLarge is sticky" {
    var f = Framer.init(testing.allocator);
    defer f.deinit();
    const hdr: Header = .{ .tag = @intFromEnum(Tag.data), .len = max_frame_len + 1 };
    try f.pushRead(std.mem.asBytes(&hdr));
    try testing.expectError(error.FrameTooLarge, f.next());
    try testing.expectError(error.FrameTooLarge, f.next());
}

fn tSockpair() ![2]posix.fd_t {
    var sp: [2]c_int = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &sp) != 0)
        return error.SocketPairFailed;
    return .{ sp[0], sp[1] };
}

fn tDaemonReply(fd: posix.fd_t, ver: u32) void {
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(testing.allocator);
    _ = recvBlocking(testing.allocator, fd, &s) catch return;
    sendBlocking(testing.allocator, fd, .{ .hello = .{ .ver = ver } }) catch {};
}

test "handshake: match, mismatch, and pre-hello daemon over socketpair" {
    var scr: std.ArrayList(u8) = .empty;
    defer scr.deinit(testing.allocator);

    // Match.
    {
        const sp = try tSockpair();
        defer for (sp) |fd| posix.close(fd);
        const t = try std.Thread.spawn(.{}, tDaemonReply, .{ sp[1], proto_version });
        defer t.join();
        try testing.expect((try handshake(testing.allocator, sp[0], &scr)) == null);
    }
    // Mismatch.
    {
        const sp = try tSockpair();
        defer for (sp) |fd| posix.close(fd);
        const t = try std.Thread.spawn(.{}, tDaemonReply, .{ sp[1], 999 });
        defer t.join();
        try testing.expectEqual(@as(?u32, 999), try handshake(testing.allocator, sp[0], &scr));
    }
    // Pre-hello daemon: closes on unknown tag → handshake reports mismatch (0).
    {
        const sp = try tSockpair();
        defer posix.close(sp[0]);
        posix.close(sp[1]); // peer gone
        try testing.expectEqual(@as(?u32, 0), try handshake(testing.allocator, sp[0], &scr));
    }
}

test "comptime: every Msg struct arm has ≤1 slice and it's last" {
    // The fixedSize() compile-error enforces this; referencing every arm
    // here makes a violation a build failure even if no test exercises it.
    inline for (@typeInfo(Msg).@"union".fields) |f| {
        if (@typeInfo(f.type) == .@"struct") _ = comptime fixedSize(f.type);
    }
}
