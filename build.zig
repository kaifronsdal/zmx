const std = @import("std");

const linux_targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
};

const macos_targets: []const std.Target.Query = &.{
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

/// One bash-driven integration test script that runs the installed `zmyth`.
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
    const version = b.option([]const u8, "version", "Version string for release") orelse
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
    const ghostty_ver = @import("build.zig.zon").dependencies.ghostty.hash;
    options.addOption([]const u8, "ghostty_version", ghostty_ver);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addOptions("build_options", options);
    addGhosttyVt(b, exe_mod, target, optimize);

    // Run
    {
        const run_step = b.step("run", "Run the app");
        const exe = b.addExecutable(.{
            .name = "zmx",
            .root_module = exe_mod,
        });
        exe.linkLibC();
        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
        run_step.dependOn(&run_cmd.step);
    }

    // Test
    {
        const test_step = b.step("test", "Run unit tests");
        const test_module = b.addModule("test", .{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        });
        addGhosttyVt(b, test_module, target, optimize);
        const exe_unit_tests = b.addTest(.{ .root_module = test_module });
        const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
        test_step.dependOn(&run_exe_unit_tests.step);
    }

    // zmyth (rewrite under src2/)
    {
        const exe2_mod = b.createModule(.{
            .root_source_file = b.path("src2/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe2_mod.addOptions("build_options", options);
        addGhosttyVt(b, exe2_mod, target, optimize);

        const exe2 = b.addExecutable(.{
            .name = "zmyth",
            .root_module = exe2_mod,
        });
        exe2.linkLibC();
        b.installArtifact(exe2);
        const step2 = b.step("zmyth", "Build the zmyth rewrite");
        step2.dependOn(&b.addInstallArtifact(exe2, .{}).step);

        const test2_mod = b.createModule(.{
            .root_source_file = b.path("src2/test.zig"),
            .target = target,
            .optimize = optimize,
        });
        test2_mod.addOptions("build_options", options);
        addGhosttyVt(b, test2_mod, target, optimize);
        const test2 = b.addTest(.{ .root_module = test2_mod });
        test2.linkLibC();
        const run_test2 = b.addRunArtifact(test2);
        const test2_step = b.step("test2", "Run src2/ unit tests");
        test2_step.dependOn(&run_test2.step);

        // Integration tests: build zmyth, then drive it via bash.
        const install_exe2 = b.addInstallArtifact(exe2, .{});
        const bin_path = b.getInstallPath(.bin, "zmyth");

        const itest_step = b.step("test-integration", "Build zmyth and run integration tests");
        for ([_][]const u8{
            "test/integration/smoke.sh",
            "test/integration/hook_test.sh",
            "test/integration/nested_test.sh",
            "test/integration/headless_query.sh",
            "test/integration/hook_assets.sh",
            // bugs.sh intentionally NOT here: it pins UNFIXED repros
            // (B12/B13) and would fail CI. Run it manually.
        }) |script| {
            itest_step.dependOn(&integrationTest(b, &install_exe2.step, bin_path, script).step);
        }

        // Prompt-engine matrix: bash/zsh/fish × none/starship/oh-my-posh.
        // Separate step because it may download engine binaries on a fresh
        // host; not part of the default test-integration target.
        const petest_step = b.step("test-prompt-engines", "Build zmyth and run the prompt-engine integration matrix");
        petest_step.dependOn(&integrationTest(
            b,
            &install_exe2.step,
            bin_path,
            "test/integration/prompt_engines.sh",
        ).step);
    }

    // Check for LSP integration
    {
        const check = b.step("check", "Check if zmx compiles");
        const exe_check = b.addExecutable(.{
            .name = "zmx",
            .root_module = exe_mod,
        });
        exe_check.linkLibC();
        check.dependOn(&exe_check.step);
    }

    // Release step - macOS can cross-compile to Linux,
    // but Linux cannot cross-compile to macOS (needs SDK)
    {
        const release_step = b.step(
            "release",
            "Build release binaries (macOS builds all, Linux builds Linux only)",
        );
        const native_os = @import("builtin").os.tag;
        const release_targets = if (native_os == .macos) linux_targets ++ macos_targets else linux_targets;
        for (release_targets) |release_target| {
            const resolved = b.resolveTargetQuery(release_target);
            const release_mod = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved,
                .optimize = .ReleaseSafe,
            });
            release_mod.addOptions("build_options", options);
            addGhosttyVt(b, release_mod, resolved, .ReleaseSafe);

            const release_exe = b.addExecutable(.{
                .name = "zmx",
                .root_module = release_mod,
            });
            release_exe.linkLibC();

            const os_name = @tagName(release_target.os_tag orelse .linux);
            const arch_name = @tagName(release_target.cpu_arch orelse .x86_64);
            const tarball_name = b.fmt("zmx-{s}-{s}-{s}.tar.gz", .{ version, os_name, arch_name });

            const tar = b.addSystemCommand(&.{ "tar", "--no-xattrs", "-czf" });

            const tarball = tar.addOutputFileArg(tarball_name);
            tar.addArg("-C");
            tar.addDirectoryArg(release_exe.getEmittedBinDirectory());
            tar.addArg("zmx");

            const shasum = b.addSystemCommand(&.{ "shasum", "-a", "256" });
            shasum.addFileArg(tarball);
            const shasum_output = shasum.captureStdOut();

            const install_tar = b.addInstallFile(tarball, b.fmt("dist/{s}", .{tarball_name}));
            const install_sha = b.addInstallFile(
                shasum_output,
                b.fmt("dist/{s}.sha256", .{tarball_name}),
            );
            release_step.dependOn(&install_tar.step);
            release_step.dependOn(&install_sha.step);
        }
    }

    // Upload artifacts to pgs
    {
        const upload_step = b.step("upload", "Upload docs and dist to pgs.sh:/zmx");
        const gen_doc = b.addSystemCommand(&.{ "sh", "-c", "cat README.md | pdocs -tmpl index.tmpl -toc | ssh pgs.sh /zmx/index.html" });
        const rsync_docs = b.addSystemCommand(&.{ "rsync", "-v", "./logo.png", "pgs.sh:/zmx/" });
        const rsync_dist = b.addSystemCommand(&.{ "rsync", "-rv", "zig-out/dist/", "pgs.sh:/zmx/a" });

        upload_step.dependOn(&gen_doc.step);
        upload_step.dependOn(&rsync_docs.step);
        upload_step.dependOn(&rsync_dist.step);
    }
}
