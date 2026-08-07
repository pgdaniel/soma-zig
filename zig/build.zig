const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // On Linux hosts, default to zig's bundled glibc: fully native builds
    // fail to link because the self-hosted linker can't handle the .sframe
    // relocations in newer system glibc's crt1.o (and use_lld segfaults the
    // 0.16.0 build runner). CPU features stay native. -Dtarget still wins.
    const default_target: std.Target.Query = if (builtin.os.tag == .linux)
        .{ .abi = .gnu, .cpu_model = .native }
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    mod.addIncludePath(b.path("vendor"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/miniaudio_impl.c"),
        .flags = &.{ "-O2", "-w" },
    });
    // miniaudio loads ALSA/Pulse/etc. at runtime via dlopen.
    mod.linkSystemLibrary("dl", .{});
    mod.linkSystemLibrary("pthread", .{});
    mod.linkSystemLibrary("m", .{});

    const exe = b.addExecutable(.{
        .name = "soma",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the SomaFM TUI");
    run_step.dependOn(&run_cmd.step);
}
