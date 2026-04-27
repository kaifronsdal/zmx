const std = @import("std");
const build_options = @import("build_options");
const client = @import("client.zig");
const io = @import("io.zig");
const outf = io.outf;
const errf = io.errf;

const usage =
    \\zmyth — minimal session manager
    \\
    \\  attach <name> [-- cmd...]             interactive (auto-create)
    \\  run    [-d] [-j] [-i] <name> -- <cmd...>   run cmd, propagate exit code
    \\         -i: return when a nested prompt appears (e.g. ssh, docker exec)
    \\  send   <name> [- | <text>]            raw PTY input, no waiting
    \\  read   <name> [-f] [-s] [-n N]
    \\  write  <name> <path>                  stdin -> file inside session
    \\  ls     [glob] [-j|-q]
    \\  wait   <name|glob>... [-j]
    \\  kill   <name|glob>... [-9]
    \\  hook   [<name>]                       install shell hook into nested shell
    \\  detach [<name>]
    \\  version | help | completions <shell>
    \\
;

pub fn main() !u8 {
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try std.fs.File.stderr().writeAll(usage);
        return 2;
    }

    const verb = args[1];
    const rest = args[2..];

    if (eq(verb, "attach")) return client.attach(allocator, rest);
    if (eq(verb, "run")) return client.run(allocator, rest);
    if (eq(verb, "send")) return client.send(allocator, rest);
    if (eq(verb, "read")) return client.read(allocator, rest);
    if (eq(verb, "write")) return client.write(allocator, rest);
    if (eq(verb, "ls") or eq(verb, "list")) return client.ls(allocator, rest);
    if (eq(verb, "wait")) return client.wait(allocator, rest);
    if (eq(verb, "kill")) return client.kill(allocator, rest);
    if (eq(verb, "hook")) return client.hook(allocator, rest);
    if (eq(verb, "detach")) return client.detach(allocator, rest);

    if (eq(verb, "version") or eq(verb, "--version") or eq(verb, "-V")) {
        try outf("zmyth {s} ({s})\n", .{ build_options.version, build_options.git_sha });
        return 0;
    }
    if (eq(verb, "help") or eq(verb, "--help") or eq(verb, "-h")) {
        try std.fs.File.stdout().writeAll(usage);
        return 0;
    }
    if (eq(verb, "completions")) return completions(rest);

    errf("zmyth: unknown command '{s}'\n\n", .{verb});
    try std.fs.File.stderr().writeAll(usage);
    return 2;
}

const comp_bash = @embedFile("assets/completions.bash");
const comp_zsh = @embedFile("assets/completions.zsh");
const comp_fish = @embedFile("assets/completions.fish");

fn completions(args: []const [:0]const u8) !u8 {
    if (args.len != 1) {
        try std.fs.File.stderr().writeAll("zmyth: completions: expected <bash|zsh|fish>\n");
        return 2;
    }
    const script: []const u8 = if (eq(args[0], "bash"))
        comp_bash
    else if (eq(args[0], "zsh"))
        comp_zsh
    else if (eq(args[0], "fish"))
        comp_fish
    else {
        errf("zmyth: completions: unknown shell '{s}'\n", .{args[0]});
        return 2;
    };
    try std.fs.File.stdout().writeAll(script);
    return 0;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
