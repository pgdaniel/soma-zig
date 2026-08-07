const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "soma",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibC();
    exe.addIncludePath(b.path("vendor"));
    exe.addCSourceFile(.{
        .file = b.path("vendor/miniaudio_impl.c"),
        .flags = &.{ "-O2", "-w" },
    });
    // miniaudio loads ALSA/Pulse/etc. at runtime via dlopen.
    exe.linkSystemLibrary("dl");
    exe.linkSystemLibrary("pthread");
    exe.linkSystemLibrary("m");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the SomaFM TUI");
    run_step.dependOn(&run_cmd.step);
}
