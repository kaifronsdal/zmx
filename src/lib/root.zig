//! libzmyth — embeddable shell-session state machine.
//!
//! Three tiers, each usable without the ones below:
//!
//!   **protocol** — `Scanner` (PTY-output OSC-2718 parser), `Classifier`
//!   (PTY-input keystroke-vs-report parser), `hook` (rc-snippet builders).
//!   Pure byte-stream functions; std + ghostty-vt only. Use this if you
//!   have your own session model and just want the parsers.
//!
//!   **`Session`** — the full state machine: ghostty Terminal + Scanner +
//!   layer stack + run queue + hook FSM. Clock-pure, fd-free; you drive it
//!   from your own event loop with seven calls.
//!
//!   **`posix`** — optional native-host glue: `Pty`, `forkExec`, `RawMode`,
//!   `Winsize`. POSIX-only. Embedders targeting wasm/Windows/in-process
//!   ignore this; native ones get the openpty/TIOCSCTTY/cfmakeraw recipe.
//!
//! Not exported: the daemon's poll loop, Unix-socket protocol, and XDG
//! directory layout — those are the `zmyth` binary's choices. `Session` is
//! clock-pure precisely so you can write a different loop.

const session = @import("session.zig");
const proto = @import("protocol.zig");
const hk = @import("hook.zig");
const inp = @import("input.zig");

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

/// Input-direction classifier: keystroke vs. terminal-generated report,
/// plus configurable Ctrl+<key> detach detection. Stateful across `feed()`.
pub const Classifier = inp.Classifier;

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
    pub const SpawnSpec = hk.SpawnSpec;
    pub const SpawnOpts = hk.SpawnOpts;
    pub const spawnSpec = hk.spawnSpec;
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

// ── tier 3: posix (optional native-host glue) ────────────────────────────
//
// `pty.zig` is the only file in the module with syscalls. Zig's lazy
// compilation means an embedder who never references `lib.posix` doesn't
// compile it — so `Session`/`Scanner`/`Classifier` stay portable.

const pty = @import("pty.zig");

pub const posix = struct {
    pub const Pty = pty.Pty;
    pub const RawMode = pty.RawMode;
    pub const Winsize = pty.Winsize;
    pub const forkExec = pty.forkExec;
    pub const getWinsize = pty.getWinsize;
    pub const setWinsize = pty.setWinsize;
    pub const setNonBlock = pty.setNonBlock;
};

test {
    _ = @import("api_test.zig");
    _ = inp;
}
