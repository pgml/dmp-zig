const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });

    const dmp = b.dependency("dmp", .{
        .target = target,
        .optimize = .ReleaseSmall,
    });
    const artifact = dmp.artifact("diffmatchpatch");

    b.getInstallStep().dependOn(&b.addInstallArtifact(artifact, .{ .dest_dir = .{ .override = .prefix } }).step);
    b.installFile("index.html", "index.html");
    b.installFile("index.js", "index.js");
    b.getInstallStep().dependOn(&b.addInstallFile(dmp.path("src/bindings/dmp.mjs"), "dmp.mjs").step);

    const run_step = b.step("serve", "Run the app");

    const serve_exe = b.addExecutable(.{
        .name = "example-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("server.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = .ReleaseFast,
        }),
    });

    const run_cmd = b.addRunArtifact(serve_exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
}
