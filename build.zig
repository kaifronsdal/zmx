const std = @import("std");

const release_targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
};

/// Attach the ghostty-vt module to `mod`. `emit-lib-vt` skips ghostty's
/// iOS-SDK probe so building on Linux without Xcode works.
fn addGhosttyVt(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    if (b.lazyDependency("ghostty", .{
        .@"emit-lib-vt" = true,
        .target = target,
        .optimize = optimize,
    })) |dep| {
        mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
}

fn module(
    b: *std.Build,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
    });
    m.addOptions("build_options", options);
    addGhosttyVt(b, m, target, optimize);
    return m;
}

/// One bash-driven integration test script that runs the installed binary.
fn integrationTest(
    b: *std.Build,
    install_step: *std.Build.Step,
    bin_path: []const u8,
    script: []const u8,
) *std.Build.Step.Run {
    const t = b.addSystemCommand(&.{"bash"});
    t.addFileArg(b.path(script));
    t.setEnvironmentVariable("ZMYTH", bin_path);
    t.has_side_effects = true; // never cache: spawns daemons, writes /tmp
    t.step.dependOn(install_step);
    return t;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Version string") orelse
        @as([]const u8, @import("build.zig.zon").version);

    var code: u8 = 0;
    const git_sha = std.mem.trim(u8, b.runAllowFail(
        &.{ "git", "rev-parse", "--short", "HEAD" },
        &code,
        .Inherit,
    ) catch "unknown", "\n");

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "git_sha", git_sha);
    options.addOption(
        []const u8,
        "ghostty_version",
        @import("build.zig.zon").dependencies.ghostty.hash,
    );

    // ── exe ──────────────────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "zmyth",
        .root_module = module(b, "src/main.zig", target, optimize, options),
    });
    exe.linkLibC();
    b.installArtifact(exe);

    const run_step = b.step("run", "Build and run zmyth");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // ── check (LSP / fast compile) ───────────────────────────────────────
    const check = b.step("check", "Type-check without emitting a binary");
    const exe_check = b.addExecutable(.{
        .name = "zmyth",
        .root_module = module(b, "src/main.zig", target, optimize, options),
    });
    exe_check.linkLibC();
    check.dependOn(&exe_check.step);

    // ── unit tests ───────────────────────────────────────────────────────
    const test_step = b.step("test", "Run unit tests");
    const unit = b.addTest(.{
        .root_module = module(b, "src/test.zig", target, optimize, options),
    });
    unit.linkLibC();
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // ── integration tests ────────────────────────────────────────────────
    const install_exe = b.addInstallArtifact(exe, .{});
    const bin_path = b.getInstallPath(.bin, "zmyth");

    const itest_step = b.step("test-integration", "Build and run integration tests");
    for ([_][]const u8{
        "test/integration/smoke.sh",
        "test/integration/hook_test.sh",
        "test/integration/nested_test.sh",
        "test/integration/headless_query.sh",
        "test/integration/hook_assets.sh",
        "test/integration/bugs.sh",
        "test/integration/write_test.sh",
    }) |script| {
        itest_step.dependOn(&integrationTest(b, &install_exe.step, bin_path, script).step);
    }

    // Prompt-engine matrix (bash/zsh/fish × none/starship/oh-my-posh) is a
    // separate step: it may download engine binaries on a fresh host.
    const petest_step = b.step("test-prompt-engines", "Run the prompt-engine integration matrix");
    petest_step.dependOn(&integrationTest(
        b,
        &install_exe.step,
        bin_path,
        "test/integration/prompt_engines.sh",
    ).step);

    const all_step = b.step("test-all", "Run unit + integration tests");
    all_step.dependOn(test_step);
    all_step.dependOn(itest_step);

    // ── release tarballs ─────────────────────────────────────────────────
    // macOS can cross-compile to Linux; Linux cannot cross-compile to macOS
    // without the SDK, so the macOS targets are skipped on a Linux host.
    const release_step = b.step("release", "Build release tarballs into zig-out/dist/");
    const native_os = @import("builtin").os.tag;
    for (release_targets) |q| {
        if (q.os_tag == .macos and native_os != .macos) continue;
        const rt = b.resolveTargetQuery(q);
        const rexe = b.addExecutable(.{
            .name = "zmyth",
            .root_module = module(b, "src/main.zig", rt, .ReleaseSafe, options),
        });
        rexe.linkLibC();

        const os_name = @tagName(q.os_tag.?);
        const arch_name = @tagName(q.cpu_arch.?);
        const tarball_name = b.fmt("zmyth-{s}-{s}-{s}.tar.gz", .{ version, os_name, arch_name });

        const tar = b.addSystemCommand(&.{ "tar", "--no-xattrs", "-czf" });
        const tarball = tar.addOutputFileArg(tarball_name);
        tar.addArg("-C");
        tar.addDirectoryArg(rexe.getEmittedBinDirectory());
        tar.addArg("zmyth");

        release_step.dependOn(&b.addInstallFile(
            tarball,
            b.fmt("dist/{s}", .{tarball_name}),
        ).step);
    }
}
