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
const sh = @import("shell.zig");

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

/// Shell-side half of OSC-2718.
pub const hook = struct {
    /// Bumped when the rc snippets change; the probe reports it so a
    /// session can decide whether to re-install.
    pub const version: u32 = sh.hook_version;

    /// One-liner that detects the running shell and any installed hook.
    /// Type this (bracketed-paste-wrapped) into an unknown shell; it emits
    /// an `Event.probe` if it's bash/zsh/fish.
    pub const probe_line: []const u8 = sh.probe_line;

    /// rc snippet that emits `preexec`/`done` OSCs.
    pub fn body(shell: Shell) []const u8 {
        return sh.hookBody(shell);
    }

    /// Full install command for `shell`: a paste-wrapped one-liner that
    /// writes `body()` to `~/.config/zmyth/hook.<shell>`, sources it, and
    /// appends a guarded source line to the shell's rc. Caller frees.
    pub fn buildInstall(gpa: @import("std").mem.Allocator, shell: Shell) ![]u8 {
        return sh.buildInstall(gpa, shell);
    }

    /// Wrap `s` as `^U \e[200~ s \e[201~ \r` for typing into a line editor.
    pub fn wrapPaste(gpa: @import("std").mem.Allocator, s: []const u8) ![]u8 {
        return sh.wrapPaste(gpa, s);
    }
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
