const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });

    const linkage = b.option(std.builtin.LinkMode, "linkage", "build lib as a dynamic lib") orelse .static;
    const strip = optimize != .Debug; //b.option(bool, "strip", "strip out debug symbals");

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_optimize = switch (optimize) {
        .Debug => optimize,
        else => .ReleaseSmall,
    };

    const isWasm = target.result.cpu.arch.isWasm();

    const mod = b.addModule("diffmatchpatch", .{
        .root_source_file = b.path("src/diffmatchpatch.zig"),
        .target = target,
        .optimize = optimize,
    });

    var lib: *std.Build.Step.Compile = undefined;
    if (isWasm) {
        lib = b.addExecutable(.{
            .name = "dmp",
            .root_module = b.createModule(.{
                .root_source_file = b.path("./src/lib.zig"),
                .target = wasm_target,
                .optimize = wasm_optimize,
                .pic = false,
                .strip = strip,
            }),
        });
        lib.rdynamic = true; // exports functions instead of export table ??
        lib.entry = .disabled;
        // lib.export_memory = true;
    } else {
        lib = b.addLibrary(.{
            .name = "diffmatchpatch",
            .root_module = b.createModule(.{
                .root_source_file = b.path("./src/lib.zig"),
                .target = target,
                .optimize = optimize,
                .pic = strip or linkage == .static,
                .strip = strip,
                .link_libc = true,
            }),
            .linkage = linkage,
        });
        // b.getInstallStep().dependOn(&b.addInstallHeaderFile(lib.getEmittedH(), "isbn.h").step);
    }

    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
