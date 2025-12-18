const std = @import("std");

pub fn build(b: *std.Build) void {
    // 1. Standard Release/Debug options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 2. Define the executable (Points to src/spider.zig)
    const exe = b.addExecutable(.{
        .name = "spider",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spider.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // 3. Install the artifact so 'zig build' creates zig-out/bin/spider
    b.installArtifact(exe);

    // 4. Create the 'zig build run' step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
