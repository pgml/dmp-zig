const std = @import("std");
const DMP = @import("diffmatchpatch");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var dmp = DMP.DiffMatchPatch.init(allocator);
    dmp.match_threshold = 0.6;

    const text1 = "There once was a time";
    const text2 = "there was a lime";

    var patches = try dmp.patchMakeStringString(init.io, text1, text2);
    defer patches.deinit();

    const diffs = try dmp.diffMainStringString(init.io, text1, text2);
    defer allocator.free(diffs);
    defer for (diffs) |d| d.deinit(allocator);

    const diffString = try dmp.diffPrettyText(diffs);
    defer allocator.free(diffString);
    const patchString = try dmp.patchToText(patches);
    defer allocator.free(patchString);

    std.debug.print("Diffs:\n{s}\nPatches\n{s}\n", .{ diffString, patchString });
}
