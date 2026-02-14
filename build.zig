const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nullTerminate = b.option(bool, "nullTerminate", "Null terminate strings") orelse false;

    const options_file = b.addWriteFiles().add("dmp_options.zig", b.fmt(
        \\ pub const nullTerminated: bool = {};
        \\ pub const StrType: type = {s};
    , .{
        nullTerminate,
        if (nullTerminate) "[:0]const u8" else "[]const u8",
    }));
    const options_mod = b.createModule(.{ .root_source_file = options_file });

    const mod = b.addModule("diffmatchpatch", .{
        .root_source_file = b.path("src/diffmatchpatch.zig"),
        .imports = &.{
            .{ .name = "dmp_options", .module = options_mod },
        },
        .target = target,
        .optimize = optimize,
    });

    const lib_unit_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
