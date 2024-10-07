// TODO: test this if possible?
// TODO: better error handling
const std = @import("std");
const builtin = @import("builtin");

const diff = @import("diff.zig");
const match = @import("match.zig");
const patch = @import("patch.zig");

const isWasm = @import("builtin").target.os.tag == .freestanding and @import("builtin").target.cpu.arch.isWasm();
const allocator = if (isWasm) std.heap.wasm_allocator else std.heap.c_allocator;

pub export fn freePatchList(patches: [*c]Patch, patches_len: c_int) callconv(.C) void {
    const patch_slice = patches[0..@intCast(patches_len)];
    defer allocator.free(patch_slice);
    for (patch_slice) |p| {
        freePatch(p);
    }
}

pub export fn freeDiffList(diffs: [*c]Diff, diffs_len: c_int) callconv(.C) void {
    const diffs_slice = diffs[0..@intCast(diffs_len)];
    defer allocator.free(diffs_slice);
    for (diffs_slice) |d| {
        freeDiff(d);
    }
}

pub export fn freePatch(p: Patch) callconv(.C) void {
    freeDiffList(p.diffs, p.diffs_len);
}

pub export fn freeDiff(d: Diff) callconv(.C) void {
    freeString(d.text);
}

pub export fn freeString(str: [*c]const u8) callconv(.C) void {
    allocator.free(std.mem.span(str));
}
pub export fn allocString(text_len: c_uint) [*c]u8 {
    const text = allocator.alloc(u8, @intCast(text_len)) catch return null;
    return text.ptr;
}

const MatchContainer = u32;

pub const DiffMatchPatch = extern struct {
    diff_timeout: f32 = 1.0,
    diff_edit_cost: c_ushort = 4,
    match_threshold: f32 = 0.5,
    match_distance: c_uint = 1000,
    patch_delete_threshold: f32 = 0.5,
    patch_margin: c_ushort = 4,
};

pub const DiffOperation = enum(c_int) {
    delete = @intFromEnum(diff.Operation.delete),
    equal = @intFromEnum(diff.Operation.equal),
    insert = @intFromEnum(diff.Operation.insert),
};

pub const Diff = extern struct {
    operation: DiffOperation,
    text: [*c]const u8,
};

pub const Patch = extern struct {
    start1: c_int,
    start2: c_int,
    length1: c_int,
    length2: c_int,
    diffs_len: c_int,
    diffs: [*c]Diff,
};

// diff ------------------

pub export fn diffDiffMain(dmp: DiffMatchPatch, text1: [*c]const u8, text2: [*c]const u8, check_lines: bool, diffs: *[*c]Diff) callconv(.C) c_int {
    if (text1 == null or text2 == null) return -1;

    const i_diffs = diff.mainStringStringBool(allocator, dmp.diff_timeout, std.mem.span(text1), std.mem.span(text2), check_lines) catch @panic("ERR");

    const o_diffs = dmpDifflistToExtern(i_diffs) catch @panic("OOM");
    diffs.* = o_diffs.ptr;
    return @intCast(i_diffs.len);
}

pub export fn diffCommonPrefix(text1: [*c]const u8, text2: [*c]const u8) callconv(.C) c_int {
    if (text1 == null or text2 == null) return -1;
    const res = diff.commonPrefix(std.mem.span(text1), std.mem.span(text2));
    return @intCast(res);
}

pub export fn diffCommonSuffix(text1: [*c]const u8, text2: [*c]const u8) callconv(.C) c_int {
    if (text1 == null or text2 == null) return -1;
    const res = diff.commonSuffix(std.mem.span(text1), std.mem.span(text2));
    return @intCast(res);
}

pub export fn diffCleanupSemantic(diffs: *[*c]Diff, diffs_len: c_int) callconv(.C) c_int {
    var i_diffs = dmpDiffListFromExtern(diffs.*[0..@intCast(diffs_len)]) catch @panic("OOM");
    // defer allocator.free(i_diffs);

    diff.cleanupSemantic(allocator, &i_diffs) catch @panic("OOM");

    const o_diffs = dmpDifflistToExtern(i_diffs) catch @panic("OOM");
    diffs.* = o_diffs.ptr;
    return @intCast(i_diffs.len);
}

pub export fn diffCleanupSemanticLossless(diffs: *[*c]Diff, diffs_len: c_int) callconv(.C) c_int {
    var i_diffs = dmpDiffListFromExtern(diffs.*[0..@intCast(diffs_len)]) catch @panic("OOM");
    // defer allocator.free(i_diffs);

    diff.cleanupSemanticLossless(allocator, &i_diffs) catch @panic("OOM");

    const o_diffs = dmpDifflistToExtern(i_diffs) catch @panic("OOM");
    diffs.* = o_diffs.ptr;
    return @intCast(i_diffs.len);
}

pub export fn diffCleanupEfficiency(dmp: DiffMatchPatch, diffs: *[*c]Diff, diffs_len: c_int) callconv(.C) c_int {
    var i_diffs = dmpDiffListFromExtern(diffs.*[0..@intCast(diffs_len)]) catch @panic("OOM");
    // defer allocator.free(i_diffs);

    diff.cleanupEfficiency(allocator, dmp.diff_edit_cost, &i_diffs) catch @panic("OOM");

    const o_diffs = dmpDifflistToExtern(i_diffs) catch @panic("OOM");
    diffs.* = o_diffs.ptr;
    return @intCast(i_diffs.len);
}

pub export fn diffCleanupMerge(diffs: *[*c]const Diff, diffs_len: c_int) callconv(.C) c_int {
    var i_diffs = dmpDiffListFromExtern(diffs.*[0..@intCast(diffs_len)]) catch @panic("OOM");
    // defer allocator.free(i_diffs);

    diff.cleanupMerge(allocator, &i_diffs) catch @panic("OOM");

    const o_diffs = dmpDifflistToExtern(i_diffs) catch @panic("OOM");
    diffs.* = o_diffs.ptr;
    return @intCast(i_diffs.len);
}

pub export fn diffXIndex(diffs: [*c]const Diff, diffs_len: c_int, loc: c_int) callconv(.C) c_int {
    const i_diffs = dmpDiffListFromExtern(diffs[0..@intCast(diffs_len)]) catch @panic("OOM");
    defer allocator.free(i_diffs);
    defer for (i_diffs) |*d| d.deinit(allocator);

    const location = diff.xIndex(i_diffs, @intCast(loc));
    return @intCast(location);
}

pub export fn diffPrettyHtml(diffs: [*c]const Diff, diffs_len: c_int) callconv(.C) [*c]const u8 {
    const i_diffs = dmpDiffListFromExtern(diffs[0..@intCast(diffs_len)]) catch @panic("OOM");
    defer allocator.free(i_diffs);
    defer for (i_diffs) |*d| d.deinit(allocator);

    const text = diff.prettyHtml(allocator, i_diffs) catch @panic("OOM");
    return text.ptr;
}

pub export fn diffPrettyText(diffs: [*c]const Diff, diffs_len: c_int) callconv(.C) [*c]const u8 {
    const i_diffs = dmpDiffListFromExtern(diffs[0..@intCast(diffs_len)]) catch @panic("OOM");
    defer allocator.free(i_diffs);
    defer for (i_diffs) |*d| d.deinit(allocator);

    const text = diff.prettyText(allocator, i_diffs) catch @panic("OOM");
    return text.ptr;
}

pub export fn diffText1(diffs: [*c]const Diff, diffs_len: c_int) callconv(.C) [*c]const u8 {
    const i_diffs = dmpDiffListFromExtern(diffs[0..@intCast(diffs_len)]) catch @panic("OOM");
    defer allocator.free(i_diffs);
    defer for (i_diffs) |*d| d.deinit(allocator);

    const text1 = diff.text1(allocator, i_diffs) catch @panic("OOM");
    return text1.ptr;
}

pub export fn diffText2(diffs: [*c]const Diff, diffs_len: c_int) callconv(.C) [*c]const u8 {
    const i_diffs = dmpDiffListFromExtern(diffs[0..@intCast(diffs_len)]) catch @panic("OOM");
    defer allocator.free(i_diffs);
    defer for (i_diffs) |*d| d.deinit(allocator);

    const text2 = diff.text2(allocator, i_diffs) catch @panic("OOM");
    return text2.ptr;
}

pub export fn diffLevenshtein(diffs: [*c]const Diff, diffs_len: c_int) callconv(.C) c_int {
    const i_diffs = dmpDiffListFromExtern(diffs[0..@intCast(diffs_len)]) catch @panic("OOM");
    defer allocator.free(i_diffs);
    defer for (i_diffs) |*d| d.deinit(allocator);

    const distance = diff.levenshtein(i_diffs);
    return @intCast(distance);
}

pub export fn diffToDelta(diffs: [*c]const Diff, diffs_len: c_int) callconv(.C) [*c]const u8 {
    const i_diffs = dmpDiffListFromExtern(diffs[0..@intCast(diffs_len)]) catch @panic("OOM");
    defer allocator.free(i_diffs);
    defer for (i_diffs) |*d| d.deinit(allocator);

    const delta = diff.toDelta(allocator, i_diffs) catch @panic("OOM");
    return delta.ptr;
}

pub export fn diffFromDelta(text: [*c]const u8, delta: [*c]const u8, out_diffs_len: *c_int) callconv(.C) [*c]Diff {
    out_diffs_len.* = -1;
    const diffs = diff.fromDelta(allocator, std.mem.span(text), std.mem.span(delta)) catch @panic("OOM");

    const o_diffs = dmpDifflistToExtern(diffs) catch @panic("OOM");
    out_diffs_len.* = @intCast(o_diffs.len);
    return o_diffs.ptr;
}

// match -----------------

pub export fn matchMain(dmp: DiffMatchPatch, text: [*c]const u8, pattern: [*c]const u8, loc: c_int) callconv(.C) c_int {
    if (text == null or pattern == null) return -1;
    const res = match.main(MatchContainer, allocator, dmp.match_distance, dmp.match_threshold, std.mem.span(text), std.mem.span(pattern), @intCast(loc)) catch null orelse return -1;
    return @intCast(res);
}

// patch -----------------

///Compute a list of patches to turn text1 into text2.
///Use diffs if provided, otherwise compute it ourselves.
///There are four ways to call this function, depending on what data is
///available to the caller:
///Method 1:
///a = text1, b = text2
///Method 2:
///a = diffs, b = diffs_len
///Method 3 (optimal):
///a = text1, b = diffs, c = diffs_len
///Method 4 (deprecated, use method 3):
///a = text1, b = text2, c = diffs, d = diffs_len
///
///returns pointer and len in out_patches_len
pub export fn patchMake(dmp: DiffMatchPatch, out_patches_len: *c_int, mode: c_int, ...) callconv(.C) [*c]Patch {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    out_patches_len.* = -1;

    const res: patch.PatchList = switch (mode) {
        1 => blk: {
            const text1: [*c]const u8 = @cVaArg(&ap, [*c]const u8);
            const text2: [*c]const u8 = @cVaArg(&ap, [*c]const u8);
            if (text1 == null or text2 == null) break :blk error.NullInputs;
            break :blk patch.makeStringString(
                MatchContainer,
                allocator,
                dmp.patch_margin,
                dmp.diff_edit_cost,
                dmp.diff_timeout,
                std.mem.span(text1),
                std.mem.span(text2),
            );
        },
        2 => blk: {
            const diffs: [*c]const Diff = @cVaArg(&ap, [*c]const Diff);
            const diffs_len: usize = @intCast(@cVaArg(&ap, c_int));
            const diff_int = dmpDiffListFromExtern(diffs[0..diffs_len]) catch @panic("OOM");
            break :blk patch.makeDiffs(MatchContainer, allocator, dmp.patch_margin, diff_int);
        },
        3 => blk: {
            const text1: [*c]const u8 = @cVaArg(&ap, [*c]const u8);
            if (text1 == null) break :blk error.NullInputs;
            const diffs: [*c]const Diff = @cVaArg(&ap, [*c]const Diff);
            const diffs_len: usize = @intCast(@cVaArg(&ap, c_int));
            const diff_int = dmpDiffListFromExtern(diffs[0..diffs_len]) catch @panic("OOM");
            break :blk patch.makeStringDiffs(MatchContainer, allocator, dmp.patch_margin, std.mem.span(text1), diff_int);
        },
        4 => blk: {
            const text1: [*c]const u8 = @cVaArg(&ap, [*c]const u8);
            const text2: [*c]const u8 = @cVaArg(&ap, [*c]const u8);
            if (text1 == null or text2 == null) break :blk error.NullInputs;
            const diffs: [*c]const Diff = @cVaArg(&ap, [*c]const Diff);
            const diffs_len: usize = @intCast(@cVaArg(&ap, c_int));
            const diff_int = dmpDiffListFromExtern(diffs[0..diffs_len]) catch @panic("OOM");
            break :blk patch.makeStringStringDiffs(MatchContainer, allocator, dmp.patch_margin, std.mem.span(text1), std.mem.span(text2), diff_int);
        },
        else => error.InvalidMode,
    } catch return null;

    const e_patches = dmpPatchlistToExtern(res) catch @panic("OOM");
    out_patches_len.* = @intCast(e_patches.len);
    return e_patches.ptr;
}

pub export fn patchDeepCopy(patches: [*c]const Patch, patches_len: c_int) callconv(.C) [*c]Patch {
    var i_patches = dmpPatchListFromExtern(patches[0..@intCast(patches_len)]) catch @panic("OOM");
    defer i_patches.deinit();

    const p_copy = patch.deepCopy(allocator, i_patches) catch @panic("OOM");

    const o_patches = dmpPatchlistToExtern(p_copy) catch @panic("OOM");
    return o_patches.ptr;
}

pub export fn patchApply(dmp: DiffMatchPatch, patches: [*c]const Patch, patches_len: c_int, text: [*c]const u8, out_applied: *[*c]bool) callconv(.C) [*c]const u8 {
    var i_patches = dmpPatchListFromExtern(patches[0..@intCast(patches_len)]) catch @panic("OOM");
    defer i_patches.deinit();

    const result, const applied = patch.apply(
        MatchContainer,
        allocator,
        dmp.diff_timeout,
        dmp.match_distance,
        dmp.match_threshold,
        dmp.patch_margin,
        dmp.patch_delete_threshold,
        i_patches,
        std.mem.span(text),
    ) catch @panic("ERR");
    out_applied.* = applied.ptr;
    return result.ptr;
}

pub export fn patchAddPadding(dmp: DiffMatchPatch, patches: [*c]const Patch, patches_len: c_int, out_patches: *[*c]Patch, out_patches_len: *c_int) callconv(.C) [*c]const u8 {
    out_patches_len.* = -1;
    out_patches.* = null;

    var i_patches = dmpPatchListFromExtern(patches[0..@intCast(patches_len)]) catch @panic("OOM");

    const padding = patch.addPadding(allocator, dmp.patch_margin, &i_patches) catch @panic("OOM");

    const o_patches = dmpPatchlistToExtern(i_patches) catch @panic("OOM");
    out_patches.* = o_patches.ptr;
    out_patches_len.* = @intCast(o_patches.len);
    return padding.ptr;
}

pub export fn patchSplitMax(dmp: DiffMatchPatch, patches: [*c]const Patch, patches_len: c_int, out_patches: *[*c]Patch, out_patches_len: *c_int) callconv(.C) void {
    out_patches_len.* = -1;
    out_patches.* = null;

    var i_patches = dmpPatchListFromExtern(patches[0..@intCast(patches_len)]) catch @panic("OOM");

    patch.splitMax(MatchContainer, allocator, dmp.patch_margin, &i_patches) catch @panic("OOM");

    const o_patches = dmpPatchlistToExtern(i_patches) catch @panic("OOM");
    out_patches.* = o_patches.ptr;
    out_patches_len.* = @intCast(o_patches.len);
    return;
}

pub export fn patchToText(patches: [*c]const Patch, patches_len: c_int) callconv(.C) [*c]const u8 {
    var i_patches = dmpPatchListFromExtern(patches[0..@intCast(patches_len)]) catch @panic("OOM");
    defer i_patches.deinit();

    const text = patch.toText(allocator, i_patches) catch @panic("OOM");
    return text.ptr;
}

pub export fn patchFromText(text: [*c]const u8, out_patches: *[*c]Patch, out_patches_len: *c_int) callconv(.C) void {
    out_patches_len.* = -1;
    out_patches.* = null;

    const i_patches = patch.fromText(allocator, std.mem.span(text)) catch @panic("OOM");

    const o_patches = dmpPatchlistToExtern(i_patches) catch @panic("OOM");
    out_patches.* = o_patches.ptr;
    out_patches_len.* = @intCast(o_patches.len);
    return;
}

pub export fn patchObjToString(p: Patch) callconv(.C) [*c]const u8 {
    var arraylist = std.ArrayList(u8).init(allocator);
    defer arraylist.deinit();

    var i_patch = dmpPatchFromExtern(p) catch @panic("OOM");
    defer i_patch.deinit(allocator);

    i_patch.format(undefined, undefined, arraylist.writer()) catch @panic("OOM");
    const text = arraylist.toOwnedSlice() catch @panic("OOM");

    return text.ptr;
}

// utils ---------------

pub fn dmpDiffListFromExtern(alloc: std.mem.Allocator, diffs: []const Diff) std.mem.Allocator.Error![]diff.Diff {
    const diff_list = try alloc.alloc(diff.Diff, diffs.len);
    for (diffs, diff_list) |d, *nd| {
        nd.* = diff.Diff{ .text = std.mem.span(@constCast(d.text)), .operation = @enumFromInt(@intFromEnum(d.operation)) };
    }
    return diff_list;
}

pub fn dmpPatchListFromExtern(alloc: std.mem.Allocator, patches: []const Patch) std.mem.Allocator.Error!patch.PatchList {
    var i_patches = try alloc.alloc(patch.Patch, patches.len);
    for (patches, 0..) |p, i| {
        i_patches[i] = try dmpPatchFromExtern(p);
    }

    return patch.PatchList{
        .allocator = alloc,
        .items = i_patches,
    };
}
pub fn dmpPatchFromExtern(alloc: std.mem.Allocator, p: Patch) std.mem.Allocator.Error!patch.Patch {
    const diffs = try alloc.alloc(diff.Diff, @intCast(p.diffs_len));
    for (p.diffs[0..@intCast(p.diffs_len)], diffs) |d, *nd| {
        nd.* = .{
            .operation = @enumFromInt(@intFromEnum(d.operation)),
            .text = @constCast(std.mem.span(d.text)),
        };
    }
    return patch.Patch.init(@intCast(p.start1), @intCast(p.start2), @intCast(p.length1), @intCast(p.length2), diffs);
}

pub fn dmpPatchlistToExtern(alloc: std.mem.allocator, patchlist: patch.PatchList) std.mem.Allocator.Error![]Patch {
    defer {
        for (patchlist.items) |p| {
            for (p.diffs) |*d| d.deinit(alloc);
            alloc.free(p.diffs);
        }
        patchlist.allocator.free(patchlist.items);
    }

    const patches = try alloc.alloc(Patch, patchlist.items.len);
    for (patchlist.items, 0..) |p, i| {
        const diffs = try alloc.alloc(Diff, p.diffs.len);
        for (p.diffs, diffs) |d, *pd| {
            pd.* = Diff{
                .operation = @enumFromInt(@intFromEnum(d.operation)),
                .text = (d.text[0.. :0]).ptr,
            };
        }

        patches[i] = Patch{
            .start1 = @intCast(p.start1),
            .start2 = @intCast(p.start2),
            .length1 = @intCast(p.length1),
            .length2 = @intCast(p.length2),
            .diffs_len = @intCast(diffs.len),
            .diffs = diffs.ptr,
        };
    }

    return patches;
}

pub fn dmpDifflistToExtern(alloc: std.mem.Allocator, diffs: []diff.Diff) std.mem.Allocator.Error![]Diff {
    defer alloc.free(diffs);

    var o_diffs = try alloc.alloc(Diff, diffs.len);
    for (diffs, 0..) |d, j| {
        o_diffs[j] = Diff{
            .operation = @enumFromInt(@intFromEnum(d.operation)),
            .text = (d.text[0.. :0]).ptr,
        };
    }

    return o_diffs;
}
