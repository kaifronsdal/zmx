//! IPC framing over a Unix stream socket.
//!
//! Wire format: 8-byte Header (1-byte tag, 3-byte zero pad, 4-byte LE len)
//! followed by `len` bytes of payload. One Framer per socket; the Framer
//! owns its read/write buffers but never touches the fd — the caller does
//! the syscalls and shovels bytes in/out.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

/// Maximum payload size accepted on the read path. Anything larger is a
/// protocol error (or DoS attempt) and yields error.FrameTooLarge.
const max_frame_len: u32 = 16 * 1024 * 1024;

pub const Tag = enum(u8) {
    // ── client → daemon ──────────────────────────────────────────────────
    attach, //     u16 cols, u16 rows, then KEY=VAL\0… env pairs
    input, //      raw stdin bytes
    resize, //     u16 cols, u16 rows
    run, //        u8 interactive (0/1), then command string
    send, //       raw bytes for PTY
    read, //       u8 mode (0=scrollback,1=screen,2=follow), u32 tail_n
    write_hdr, //  u64 encoded-body length, then target path string
    write_data, // chunk of base64; empty = EOF
    info, //       (empty)
    wait, //       (empty)
    kill, //       u8 signal (default SIGTERM)
    detach, //     (empty)
    hook, //       (empty)
    // ── daemon → client ──────────────────────────────────────────────────
    output, //     raw PTY bytes
    state, //      attach replay (chunked)
    run_done, //   RunDoneWire
    info_reply, // JSON
    data, //       read response (chunked)
    ack, //        optional message string
    err, //        message string
    eof, //        (empty)
    _, // non-exhaustive: unknown tags are returned to the caller, who may skip
};

const Header = extern struct {
    tag: Tag,
    _pad: [3]u8 = .{ 0, 0, 0 },
    /// Payload length in bytes. Native (little) endian on the wire; daemon
    /// and client are always the same arch.
    len: u32,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 8);
}

pub const Message = struct {
    tag: Tag,
    payload: []const u8,
};

/// Wire encoding of a `.run_done` payload.
pub const RunDoneWire = extern struct {
    /// `null_exit` encodes "null / unknown".
    exit_code: i32,
    via: Via,
    _pad: [3]u8 = .{ 0, 0, 0 },
    dur_ms: u64,

    pub const Via = enum(u8) {
        osc_done,
        prompt_fallback,
        pty_eof,
        line_rejected,
        /// `run -i`: a nested prompt appeared (via ?2004h or a new-pid `done`).
        at_prompt,
        /// The layer this run was typed into exited (e.g. ssh dropped) before
        /// the run's own `done` arrived. exit_code is the parent's `done` ec.
        layer_exited,
        _,
    };
    pub const null_exit: i32 = std.math.minInt(i32);

    pub fn exitCode(self: RunDoneWire) ?i32 {
        return if (self.exit_code == null_exit) null else self.exit_code;
    }

    pub fn decode(bytes: []const u8) ?RunDoneWire {
        if (bytes.len != @sizeOf(RunDoneWire)) return null;
        var w: RunDoneWire = undefined;
        @memcpy(std.mem.asBytes(&w), bytes);
        return w;
    }
};

comptime {
    std.debug.assert(@sizeOf(RunDoneWire) == 16);
}

pub const Framer = struct {
    gpa: Allocator,

    read_buf: std.ArrayList(u8) = .empty,
    /// Bytes in read_buf[0..read_pos] have been returned by next() and may
    /// be discarded on the next pushRead() / next() call.
    read_pos: usize = 0,

    write_buf: std.ArrayList(u8) = .empty,
    /// Bytes in write_buf[0..write_pos] have been confirmed written via
    /// consumeWrite().
    write_pos: usize = 0,

    pub fn init(allocator: Allocator) Framer {
        return .{ .gpa = allocator };
    }

    pub fn deinit(self: *Framer) void {
        self.read_buf.deinit(self.gpa);
        self.write_buf.deinit(self.gpa);
        self.* = undefined;
    }

    /// Drop bytes already consumed by next(), shifting any tail down to
    /// index 0. Called lazily so the slice returned by next() stays valid
    /// until the *following* next()/pushRead().
    fn compactRead(self: *Framer) void {
        if (self.read_pos == 0) return;
        const tail = self.read_buf.items[self.read_pos..];
        std.mem.copyForwards(u8, self.read_buf.items[0..tail.len], tail);
        self.read_buf.items.len = tail.len;
        self.read_pos = 0;
    }

    /// Hand bytes just read from the socket to the framer. Invalidates any
    /// payload slice previously returned by next().
    pub fn pushRead(self: *Framer, bytes: []const u8) !void {
        self.compactRead();
        try self.read_buf.appendSlice(self.gpa, bytes);
    }

    /// Pop one complete frame if available. The returned payload slices into
    /// the Framer's internal buffer and is valid until the next call to
    /// pushRead() or next(). Returns null if a full frame is not yet
    /// buffered.
    pub fn next(self: *Framer) error{FrameTooLarge}!?Message {
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
        return .{ .tag = hdr.tag, .payload = payload };
    }

    /// Append a frame (header + payload) to the outbound buffer. Reserves
    /// space for both up front so OOM can't leave a torn header behind.
    pub fn queue(self: *Framer, tag: Tag, payload: []const u8) !void {
        if (payload.len > max_frame_len) return error.FrameTooLarge;
        const hdr: Header = .{ .tag = tag, .len = @intCast(payload.len) };
        try self.write_buf.ensureUnusedCapacity(self.gpa, @sizeOf(Header) + payload.len);
        self.write_buf.appendSliceAssumeCapacity(std.mem.asBytes(&hdr));
        self.write_buf.appendSliceAssumeCapacity(payload);
    }

    /// Slice of bytes waiting to be written to the socket.
    pub fn pendingWrite(self: *const Framer) []const u8 {
        return self.write_buf.items[self.write_pos..];
    }

    pub fn hasPendingWrite(self: *const Framer) bool {
        return self.write_pos < self.write_buf.items.len;
    }

    /// Record that `n` bytes of pendingWrite() were successfully written.
    pub fn consumeWrite(self: *Framer, n: usize) void {
        std.debug.assert(self.write_pos + n <= self.write_buf.items.len);
        self.write_pos += n;
        if (self.write_pos == self.write_buf.items.len) {
            self.write_buf.clearRetainingCapacity();
            self.write_pos = 0;
        }
    }
};

// ---------------------------------------------------------------------------
// Blocking convenience helpers (for simple clients; the daemon poll loop
// uses Framer directly).
// ---------------------------------------------------------------------------

const writeAll = @import("io.zig").writeAllFd;

fn readExact(fd: posix.fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try posix.read(fd, buf[off..]);
        if (n == 0) return error.UnexpectedEof;
        off += n;
    }
}

/// Send one frame, blocking until fully written.
pub fn sendBlocking(fd: posix.fd_t, tag: Tag, payload: []const u8) !void {
    if (payload.len > max_frame_len) return error.FrameTooLarge;
    const hdr: Header = .{ .tag = tag, .len = @intCast(payload.len) };
    try writeAll(fd, std.mem.asBytes(&hdr));
    try writeAll(fd, payload);
}

const Owned = struct { tag: Tag, payload: []u8 };

/// Receive one frame, blocking until complete. Caller owns and must free
/// `payload` with the same allocator.
pub fn recvBlocking(allocator: Allocator, fd: posix.fd_t) !Owned {
    var hdr: Header = undefined;
    try readExact(fd, std.mem.asBytes(&hdr));
    if (hdr.len > max_frame_len) return error.FrameTooLarge;
    const payload = try allocator.alloc(u8, hdr.len);
    errdefer allocator.free(payload);
    try readExact(fd, payload);
    return .{ .tag = hdr.tag, .payload = payload };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "round-trip three frames" {
    var src = Framer.init(testing.allocator);
    defer src.deinit();

    try src.queue(.attach, "hello");
    try src.queue(.input, "");
    try src.queue(.output, "world!!");

    const wire = src.pendingWrite();
    try testing.expectEqual(@as(usize, 3 * @sizeOf(Header) + 5 + 0 + 7), wire.len);

    var dst = Framer.init(testing.allocator);
    defer dst.deinit();
    try dst.pushRead(wire);

    const m0 = (try dst.next()).?;
    try testing.expectEqual(Tag.attach, m0.tag);
    try testing.expectEqualStrings("hello", m0.payload);

    const m1 = (try dst.next()).?;
    try testing.expectEqual(Tag.input, m1.tag);
    try testing.expectEqualStrings("", m1.payload);

    const m2 = (try dst.next()).?;
    try testing.expectEqual(Tag.output, m2.tag);
    try testing.expectEqualStrings("world!!", m2.payload);

    try testing.expectEqual(@as(?Message, null), try dst.next());
}

test "header split across reads" {
    var src = Framer.init(testing.allocator);
    defer src.deinit();
    try src.queue(.ack, "ok");
    const wire = src.pendingWrite();

    var dst = Framer.init(testing.allocator);
    defer dst.deinit();

    try dst.pushRead(wire[0..5]);
    try testing.expectEqual(@as(?Message, null), try dst.next());

    try dst.pushRead(wire[5..]);
    const m = (try dst.next()).?;
    try testing.expectEqual(Tag.ack, m.tag);
    try testing.expectEqualStrings("ok", m.payload);
    try testing.expectEqual(@as(?Message, null), try dst.next());
}

test "payload split at every offset" {
    var src = Framer.init(testing.allocator);
    defer src.deinit();
    try src.queue(.data, "abcdefghij");
    const wire = src.pendingWrite();

    var i: usize = 1;
    while (i < wire.len) : (i += 1) {
        var dst = Framer.init(testing.allocator);
        defer dst.deinit();

        try dst.pushRead(wire[0..i]);
        try testing.expectEqual(@as(?Message, null), try dst.next());
        try dst.pushRead(wire[i..]);
        const m = (try dst.next()).?;
        try testing.expectEqual(Tag.data, m.tag);
        try testing.expectEqualStrings("abcdefghij", m.payload);
        try testing.expectEqual(@as(?Message, null), try dst.next());
    }
}

test "two frames coalesced in one read" {
    var src = Framer.init(testing.allocator);
    defer src.deinit();
    try src.queue(.state, "A");
    try src.queue(.err, "BB");

    var dst = Framer.init(testing.allocator);
    defer dst.deinit();
    try dst.pushRead(src.pendingWrite());

    const a = (try dst.next()).?;
    try testing.expectEqual(Tag.state, a.tag);
    try testing.expectEqualStrings("A", a.payload);

    const b = (try dst.next()).?;
    try testing.expectEqual(Tag.err, b.tag);
    try testing.expectEqualStrings("BB", b.payload);

    try testing.expectEqual(@as(?Message, null), try dst.next());
}

test "consumeWrite partial" {
    var f = Framer.init(testing.allocator);
    defer f.deinit();

    try f.queue(.info, "xyz");
    const total = @sizeOf(Header) + 3;
    try testing.expectEqual(total, f.pendingWrite().len);
    try testing.expect(f.hasPendingWrite());

    f.consumeWrite(3);
    try testing.expectEqual(total - 3, f.pendingWrite().len);
    try testing.expect(f.hasPendingWrite());

    f.consumeWrite(total - 3);
    try testing.expectEqual(@as(usize, 0), f.pendingWrite().len);
    try testing.expect(!f.hasPendingWrite());

    // Buffer reset: queueing again starts fresh.
    try f.queue(.eof, "");
    try testing.expectEqual(@as(usize, @sizeOf(Header)), f.pendingWrite().len);
}

test "FrameTooLarge" {
    var f = Framer.init(testing.allocator);
    defer f.deinit();

    const hdr: Header = .{ .tag = .data, .len = 32 * 1024 * 1024 };
    try f.pushRead(std.mem.asBytes(&hdr));
    try testing.expectError(error.FrameTooLarge, f.next());
}

test "unknown tag is passed through" {
    var f = Framer.init(testing.allocator);
    defer f.deinit();

    const unknown: Tag = @enumFromInt(200);
    const hdr: Header = .{ .tag = unknown, .len = 1 };
    try f.pushRead(std.mem.asBytes(&hdr));
    try f.pushRead("Z");

    const m = (try f.next()).?;
    try testing.expectEqual(@as(u8, 200), @intFromEnum(m.tag));
    try testing.expectEqualStrings("Z", m.payload);
}

test "RunDoneWire round-trip" {
    const w: RunDoneWire = .{ .exit_code = 42, .via = .osc_done, .dur_ms = 1234 };
    const bytes = std.mem.asBytes(&w);
    try testing.expectEqual(@as(usize, 16), bytes.len);

    const back = RunDoneWire.decode(bytes).?;
    try testing.expectEqual(@as(?i32, 42), back.exitCode());
    try testing.expectEqual(RunDoneWire.Via.osc_done, back.via);
    try testing.expectEqual(@as(u64, 1234), back.dur_ms);

    // null exit code encodes as i32 min
    const w2: RunDoneWire = .{ .exit_code = RunDoneWire.null_exit, .via = .line_rejected, .dur_ms = 0 };
    try testing.expectEqual(@as(?i32, null), w2.exitCode());

    // wrong-length decode -> null
    try testing.expectEqual(@as(?RunDoneWire, null), RunDoneWire.decode(bytes[0..8]));
}

test "len == max_frame_len is accepted (boundary)" {
    var f = Framer.init(testing.allocator);
    defer f.deinit();

    const hdr: Header = .{ .tag = .data, .len = max_frame_len };
    try f.pushRead(std.mem.asBytes(&hdr));
    // Header parses cleanly; we're just short the payload. Not an error.
    try testing.expectEqual(@as(?Message, null), try f.next());
}

test "FrameTooLarge is sticky until socket dropped" {
    // After a bad header the read buffer is not advanced (we never learned a
    // valid frame boundary), so subsequent next() calls re-hit the same bad
    // header. This is intentional: the stream is desynchronised and the only
    // safe recovery is for the caller to close the socket.
    var f = Framer.init(testing.allocator);
    defer f.deinit();

    const hdr: Header = .{ .tag = .data, .len = max_frame_len + 1 };
    try f.pushRead(std.mem.asBytes(&hdr));
    try testing.expectError(error.FrameTooLarge, f.next());
    try testing.expectError(error.FrameTooLarge, f.next());
    // Even pushing more bytes doesn't help — the bad header is still at [0].
    try f.pushRead("garbage");
    try testing.expectError(error.FrameTooLarge, f.next());
}

test "Header layout" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Header));
    try testing.expectEqual(@as(usize, 0), @offsetOf(Header, "tag"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(Header, "len"));

    const hdr: Header = .{ .tag = .attach, .len = 0 };
    const bytes = std.mem.asBytes(&hdr);
    try testing.expectEqual(@as(u8, 0), bytes[1]);
    try testing.expectEqual(@as(u8, 0), bytes[2]);
    try testing.expectEqual(@as(u8, 0), bytes[3]);
}
