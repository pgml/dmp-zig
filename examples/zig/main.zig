const std = @import("std");
const DMP = @import("diffmatchpatch");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer if (gpa.deinit() == .leak) std.debug.print("Leaks!!!!!\n", .{});
    const allocator = gpa.allocator();

    var dmp = DMP.DiffMatchPatch.init(allocator);
    dmp.match_threshold = 0.6;

    const text1 = "There once was a time";
    const text2 = "there was a lime";

    var patches = try dmp.patchMakeStringString(text1, text2);
    defer patches.deinit();

    const diffs = try dmp.diffMainStringString(text1, text2);
    defer allocator.free(diffs);
    defer for (diffs) |*d| d.deinit(allocator);

    const diffString = try dmp.diffPrettyText(diffs);
    defer allocator.free(diffString);
    const patchString = try dmp.patchToText(patches);
    defer allocator.free(patchString);

    std.debug.print("Diffs:\n{s}\nPatches\n{s}\n", .{ diffString, patchString });
}
