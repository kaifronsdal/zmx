//! libzmyth — embeddable shell-session state machine.
//!
//! Two tiers:
//!
//!   `protocol` + `hook` — the OSC-2718 shell-integration protocol on its
//!   own. Feed PTY bytes through `Scanner`; type `hook.probe_line` /
//!   `hook.buildInstall()` into a shell to make it emit those OSCs. No
//!   ghostty dependency. Use this if you have your own session model and
//!   just want preexec/done/probe events.
//!
//!   `Session` — the full state machine: ghostty Terminal + Scanner +
//!   layer stack + run queue + hook FSM. Clock-pure; you drive it from
//!   your own event loop with seven calls. See the `Session` doc comment
//!   for the loop shape.
//!
//! Not exported: the daemon (fork/socket/XDG) and IPC framing — those are
//! the `zmyth` binary's policy, not reusable mechanism. The `write` verb's
//! chunked-ack handshake similarly lives in the daemon.

const session = @import("session.zig");
const proto = @import("protocol.zig");
const hk = @import("hook.zig");

// ── tier 1: protocol ─────────────────────────────────────────────────────

/// Streaming scanner for OSC-2718 / `?2004h` / OSC 133;D in a PTY byte
/// stream. Stateful (handles markers split across `feed()` calls).
///
/// `Event.done.cwd` and `Event.pwd` borrow scanner-internal storage that's
/// reused on the next `recycleSlices()` — copy out before then.
pub const Scanner = proto.Scanner;
pub const Event = proto.Event;
pub const Shell = proto.Shell;
pub const Done = proto.Done;
pub const ProbeResult = proto.ProbeResult;

/// Shell-side half of OSC-2718: hook scripts, probe/install one-liners,
/// the `write` opener, and shell-string quoting.
pub const hook = struct {
    pub const version: u32 = hk.hook_version;
    pub const dir: []const u8 = hk.hook_dir;
    pub const probe_line: []const u8 = hk.probe_line;
    pub const body = hk.hookBody;
    pub const rcSourceLine = hk.rcSourceLine;
    pub const buildInstall = hk.buildInstall;
    pub const wrapPaste = hk.wrapPaste;
    pub const writeOpener = hk.writeOpener;
    pub const writeEncLen = hk.writeEncLen;
    pub const posixQuote = hk.posixQuote;
};

// ── tier 2: Session ──────────────────────────────────────────────────────

pub const Session = session.Session;
pub const Options = session.Options;
pub const State = session.State;
pub const SessionEvent = session.SessionEvent;
pub const Via = session.Via;
pub const HookResult = session.HookResult;
pub const DumpMode = session.DumpMode;
pub const Error = session.Error;

test {
    _ = @import("api_test.zig");
}
