// TODO: test this if possible?
// TODO: better error handling
// TODO: improve wasm parts, cant get out of memory
const std = @import("std");
const builtin = @import("builtin");

const diff = @import("diff.zig");
const match = @import("match.zig");
const patch = @import("patch.zig");

const isWasm = @import("builtin").target.os.tag == .freestanding and @import("builtin").target.cpu.arch.isWasm();
const allocator = if (isWasm) std.heap.wasm_allocator else std.heap.c_allocator;

pub const ErrSource = enum(u32) {
    none,
    function_alloc,
    function_free,
    function_alloc_string,
    function_free_string,
    function_free_patch_list,
    function_free_diffs_list,

    function_match_main,

    function_patch_make,
    function_patch_deep_copy,
    function_patch_apply,
    function_patch_add_padding,
    function_patch_split_max,
    function_patch_to_text,
    function_patch_from_text,
    function_patch_obj_to_string,

    function_diff_diff_main,
    function_diff_common_prefix,
    function_diff_common_suffix,
    function_diff_cleanup_semantic,
    function_diff_cleanup_semantic_lossless,
    function_diff_cleanup_efficiency,
    function_diff_cleanup_merge,
    function_diff_x_index,
    function_diff_pretty_html,
    function_diff_pretty_text,
    function_diff_text1,
    function_diff_text2,
    function_diff_levenshtein,
    function_diff_to_delta,
    function_diff_from_delta,
};

const Errors = error{
    OutOfMemory,
    PatternTooLong,
    InvalidUtf8,
    WriteFailed, // TODO: simplify -- remove
    InvalidPatchMode,
    InvalidPatchString,
    NullInputs,
    DeltaContainsIlligalOperation,
    DeltaContainsInvalidUTF8,
    DeltaContainsNegetiveNumber,
    DeltaLongerThenSource,
    DeltaShorterThenSource,
    DeltaBadNumber,

    InvalidMode, // NOTE: maybe make a new string with info
};

fn callErrorHandled(source: ErrSource, err: Errors) void {
    callOnError(source, switch (err) {
        error.PatternTooLong => "Pattern too long",
        error.OutOfMemory => "Out of memory",
        error.DeltaContainsInvalidUTF8, error.InvalidUtf8 => "Invalid utf8 provided",
        error.WriteFailed => "Error making string",
        error.InvalidMode => "Invalid patch mode provided",
        error.NullInputs => "One or more of the provided inputs are null",
        error.InvalidPatchMode => "Invalid patch operation",
        error.InvalidPatchString => "Invalid patch string",
        error.DeltaContainsIlligalOperation => "Invalid operation in delta",
        error.DeltaContainsNegetiveNumber => "Delta contains negative number",
        error.DeltaLongerThenSource => "Delta longer then source",
        error.DeltaShorterThenSource => "Delta shorter then source",
        error.DeltaBadNumber => "Delta contains a bad number",
    });
}

var lastError = ErrorInfo{ .source = .none, .message = "" };
const ErrorInfo = extern struct {
    source: ErrSource,
    message: [*:0]const u8,
};

// For WASM: extern function (required)
// For lib: extern var (optional function pointer)
var onError = if (isWasm)
    @extern(*const fn (err: ErrorInfo) callconv(.c) void, .{ .name = "onError" })
else
    @extern(?*const fn (err: ErrorInfo) callconv(.c) void, .{ .name = "onError" });

fn callOnError(source: ErrSource, err: [*:0]const u8) void {
    lastError = .{
        .source = source,
        .message = err,
    };

    if (isWasm) {
        onError(lastError);
    } else {
        if (onError) |callback| {
            callback(lastError);
        }
    }
}

export fn getLastError(err: *ErrorInfo) void {
    err.* = lastError;
}

export fn freePatchList(patches: [*c]Patch, patches_len: c_int) callconv(.c) void {
    if (patches == 0 or patches == null) {
        callOnError(.function_free_patch_list, "Cannot free 0");
        return;
    }

    const patch_slice = patches[0..@intCast(patches_len)];
    defer allocator.free(patch_slice);
    for (patch_slice) |p| {
        freePatch(p);
    }
}

export fn freeDiffList(diffs: [*c]Diff, diffs_len: c_int) callconv(.c) void {
    if (diffs == 0 or diffs == null) {
        callOnError(.function_free_diffs_list, "Cannot free 0");
        return;
    }

    const diffs_slice = diffs[0..@intCast(diffs_len)];
    defer allocator.free(diffs_slice);
    for (diffs_slice) |d| {
        freeDiff(d);
    }
}

export fn freePatch(p: Patch) callconv(.c) void {
    freeDiffList(p.diffs, p.diffs_len);
}

export fn freeDiff(d: Diff) callconv(.c) void {
    freeString(d.text);
}

export fn freeString(str: [*c]const u8) callconv(.c) void {
    if (str == 0 or str == null) {
        callOnError(.function_free_string, "Cannot free 0");
        return;
    }

    allocator.free(std.mem.span(str));
}
export fn allocString(text_len: c_uint) [*c]u8 {
    const text = allocator.alloc(u8, @intCast(text_len)) catch {
        callOnError(.function_alloc_string, "Error allocating memory");
        return null;
    };
    return text.ptr;
}

fn allocFn(len: usize) callconv(.c) usize {
    const mem = allocator.alloc(u8, len) catch {
        callOnError(.function_alloc, "Error allocating memory");
        return 0;
    };
    return @intFromPtr(mem.ptr);
}
fn free(ptr: usize, len: usize) callconv(.c) void {
    if (ptr == 0) {
        callOnError(.function_free, "Cannot free 0");
        return;
    }
    const pointer: [*]u8 = @ptrFromInt(ptr);
    const slice = pointer[0..len];
    allocator.free(slice);
}

comptime {
    if (isWasm) {
        @export(&allocFn, .{ .name = "alloc" });
        @export(&free, .{ .name = "free" });
    }
}

const MatchContainer = u32;

const DiffMatchPatch = extern struct {
    diff_timeout: f32 = 1.0,
    diff_edit_cost: c_ushort = 4,
    match_threshold: f32 = 0.5,
    match_distance: c_uint = 1000,
    patch_delete_threshold: f32 = 0.5,
    patch_margin: c_ushort = 4,
};

const DiffOperation = enum(c_int) {
    delete = @intFromEnum(diff.Operation.delete),
    equal = @intFromEnum(diff.Operation.equal),
    insert = @intFromEnum(diff.Operation.insert),
};

const Diff = extern struct {
    operation: DiffOperation,
    text: [*c]const u8,
};

const Patch = extern struct {
    start1: c_int,
    start2: c_int,
    length1: c_int,
    length2: c_int,
    diffs_len: c_int,
    diffs: [*c]Diff,
};

// diff ------------------

export fn diffDiffMain(dmp: DiffMatchPatch, text1: [*c]const u8, text2: [*c]const u8, check_lines: bool, diffs: *[*c]Diff) callconv(.c) c_int {
    if (text1 == null or text2 == null) {
        callErrorHandled(.function_diff_diff_main, error.NullInputs);
        return -1;
    }

    const i_diffs = diff.mainStringStringBool(allocator, dmp.diff_timeout, std.mem.span(text1), std.mem.span(text2), check_lines) catch |err| {
        callErrorHandled(.function_diff_diff_main, err);
        return -1;
    };

    const o_diffs = dmpDifflistToExtern(allocator, i_diffs) catch |err| {
        callErrorHandled(.function_diff_diff_main, err);
        return -1;
    };
    diffs.* = o_diffs.ptr;
    return @intCast(i_diffs.len);
}

export fn diffCommonPrefix(text1: [*c]const u8, text2: [*c]const u8) callconv(.c) c_int {
    if (text1 == null or text2 == null) return -1;
    const res = diff.commonPrefix(std.mem.span(text1), std.mem.span(text2));
    return @intCast(res);
}

export fn diffCommonSuffix(text1: [*c]const u8, text2: [*c]const u8) callconv(.c) c_int {
    if (text1 == null or text2 == null) return -1;
    const res = diff.commonSuffix(std.mem.span(text1), std.mem.span(text2));
    return @intCast(res);
}

export fn diffCleanupSemantic(diffs: *[*c]Diff, diffs_len: c_int) callconv(.c) c_int {
    var i_diffs = dmpDiffListFromExtern(allocator, diffs.*[0..@intCast(diffs_len)]) catch |err| {
        callErrorHandled(.function_diff_cleanup_semantic, err);
        return -1;
    };
    // defer allocator.free(i_diffs);

    diff.cleanupSemantic(allocator, &i_diffs) catch |err| {
        callErrorHandled(.function_diff_cleanup_semantic, err);
        return -1;
    };

    const o_diffs = dmpDifflistToExtern(allocator, i_diffs) catch |err| {
        callErrorHandled(.function_diff_cleanup_semantic, err);
        return -1;
    };
    diffs.* = o_diffs.ptr;
    return @intCast(i_diffs.len);
}

export fn diffCleanupSemanticLossless(diffs: *[*c]Diff, diffs_len: c_int) callconv(.c) c_int {
    var i_diffs = dmpDiffListFromExtern(allocator, diffs.*[0..@intCast(diffs_len)]) catch |err| {
        callErrorHandled(.function_diff_cleanup_semantic_lossless, err);
        return -1;
    };
    // defer allocator.free(i_diffs);

    diff.cleanupSemanticLossless(allocator, &i_diffs) catch |err| {
        callErrorHandled(.function_diff_cleanup_semantic_lossless, err);
        return -1;
    };

    const o_diffs = dmpDifflistToExtern(allocator, i_diffs) catch |err| {
        callErrorHandled(.function_diff_cleanup_semantic_lossless, err);
        return -1;
    };
    diffs.* = o_diffs.ptr;
    return @intCast(i_diffs.len);
}

export fn diffCleanupEfficiency(dmp: DiffMatchPatch, diffs: *[*c]Diff, diffs_len: c_int) callconv(.c) c_int {
    var i_diffs = dmpDiffListFromExtern(allocator, diffs.*[0..@intCast(diffs_len)]) catch |err| {
        callErrorHandled(.function_diff_cleanup_efficiency, err);
        return -1;
    };
    // defer allocator.free(i_diffs);

    diff.cleanupEfficiency(allocator, dmp.diff_edit_cost, &i_diffs) catch |err| {
        callErrorHandled(.function_diff_cleanup_efficiency, err);
        return -1;
    };

    const o_diffs = dmpDifflistToExtern(allocator, i_diffs) catch |err| {
        callErrorHandled(.function_diff_cleanup_efficiency, err);
        return -1;
    };
    diffs.* = o_diffs.ptr;
    return @intCast(i_diffs.len);
}

export fn diffCleanupMerge(diffs: *[*c]const Diff, diffs_len: c_int) callconv(.c) c_int {
    var i_diffs = dmpDiffListFromExtern(allocator, diffs.*[0..@intCast(diffs_len)]) catch |err| {
        callErrorHandled(.function_diff_cleanup_merge, err);
        return -1;
    };
    // defer allocator.free(i_diffs);

    diff.cleanupMerge(allocator, &i_diffs) catch |err| {
        callErrorHandled(.function_diff_cleanup_merge, err);
        return -1;
    };

    const o_diffs = dmpDifflistToExtern(allocator, i_diffs) catch |err| {
        callErrorHandled(.function_diff_cleanup_merge, err);
        return -1;
    };
    diffs.* = o_diffs.ptr;
    return @intCast(i_diffs.len);
}

export fn diffXIndex(diffs: [*c]const Diff, diffs_len: c_int, loc: c_int) callconv(.c) c_int {
    const i_diffs = dmpDiffListFromExtern(allocator, diffs[0..@intCast(diffs_len)]) catch |err| {
        callErrorHandled(.function_diff_x_index, err);
        return -1;
    };
    defer allocator.free(i_diffs);
    defer for (i_diffs) |*d| d.deinit(allocator);

    const location = diff.xIndex(i_diffs, @intCast(loc));
    return @intCast(location);
}

export fn diffPrettyHtml(diffs: [*c]const Diff, diffs_len: c_int) callconv(.c) [*c]const u8 {
    const i_diffs = dmpDiffListFromExtern(allocator, diffs[0..@intCast(diffs_len)]) catch |err| {
        callErrorHandled(.function_diff_pretty_html, err);
        return null;
    };
    defer allocator.free(i_diffs);
    defer for (i_diffs) |*d| d.deinit(allocator);

    const text = diff.prettyHtml(allocator, i_diffs) catch |err| {
        callErrorHandled(.function_diff_pretty_html, err);
        return null;
    };
    return text.ptr;
}

export fn diffPrettyText(diffs: [*c]const Diff, diffs_len: c_int) callconv(.c) [*c]const u8 {
    const i_diffs = dmpDiffListFromExtern(allocator, diffs[0..@intCast(diffs_len)]) catch |err| {
        callErrorHandled(.function_diff_pretty_text, err);
        return null;
    };
    defer allocator.free(i_diffs);
    defer for (i_diffs) |*d| d.deinit(allocator);

    const text = diff.prettyText(allocator, i_diffs) catch |err| {
        callErrorHandled(.function_diff_pretty_text, err);
        return null;
    };
    return text.ptr;
}

export fn diffText1(diffs: [*c]const Diff, diffs_len: c_int) callconv(.c) [*c]const u8 {
    const i_diffs = dmpDiffListFromExtern(allocator, diffs[0..@intCast(diffs_len)]) catch |err| {
        callErrorHandled(.function_diff_text1, err);
        return null;
    };
    defer allocator.free(i_diffs);
    defer for (i_diffs) |*d| d.deinit(allocator);

    const text1 = diff.text1(allocator, i_diffs) catch |err| {
        callErrorHandled(.function_diff_text1, err);
        return null;
    };
    return text1.ptr;
}

export fn diffText2(diffs: [*c]const Diff, diffs_len: c_int) callconv(.c) [*c]const u8 {
    const i_diffs = dmpDiffListFromExtern(allocator, diffs[0..@intCast(diffs_len)]) catch |err| {
        callErrorHandled(.function_diff_text2, err);
        return null;
    };
    defer allocator.free(i_diffs);
    defer for (i_diffs) |*d| d.deinit(allocator);

    const text2 = diff.text2(allocator, i_diffs) catch |err| {
        callErrorHandled(.function_diff_text2, err);
        return null;
    };
    return text2.ptr;
}

export fn diffLevenshtein(diffs: [*c]const Diff, diffs_len: c_int) callconv(.c) c_int {
    const i_diffs = dmpDiffListFromExtern(allocator, diffs[0..@intCast(diffs_len)]) catch |err| {
        callErrorHandled(.function_diff_levenshtein, err);
        return -1;
    };
    defer allocator.free(i_diffs);
    defer for (i_diffs) |*d| d.deinit(allocator);

    const distance = diff.levenshtein(i_diffs);
    return @intCast(distance);
}

export fn diffToDelta(diffs: [*c]const Diff, diffs_len: c_int) callconv(.c) [*c]const u8 {
    const i_diffs = dmpDiffListFromExtern(allocator, diffs[0..@intCast(diffs_len)]) catch |err| {
        callErrorHandled(.function_diff_to_delta, err);
        return null;
    };
    defer allocator.free(i_diffs);
    defer for (i_diffs) |*d| d.deinit(allocator);

    const delta = diff.toDelta(allocator, i_diffs) catch |err| {
        callErrorHandled(.function_diff_to_delta, err);
        return null;
    };
    return delta.ptr;
}

export fn diffFromDelta(text: [*c]const u8, delta: [*c]const u8, out_diffs_len: *c_int) callconv(.c) [*c]Diff {
    out_diffs_len.* = -1;
    const diffs = diff.fromDelta(allocator, std.mem.span(text), std.mem.span(delta)) catch |err| {
        callErrorHandled(.function_diff_from_delta, err);
        return null;
    };

    const o_diffs = dmpDifflistToExtern(allocator, diffs) catch |err| {
        callErrorHandled(.function_diff_from_delta, err);
        return null;
    };
    out_diffs_len.* = @intCast(o_diffs.len);
    return o_diffs.ptr;
}

// match -----------------

export fn matchMain(dmp: DiffMatchPatch, text: [*c]const u8, pattern: [*c]const u8, loc: c_int) callconv(.c) c_int {
    if (text == null or pattern == null) return -1;
    const res = match.main(
        MatchContainer,
        allocator,
        dmp.match_distance,
        dmp.match_threshold,
        std.mem.span(text),
        std.mem.span(pattern),
        @intCast(loc),
    ) catch |err| {
        callErrorHandled(.function_match_main, err);
        return 0;
    } orelse return -1;
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
export fn patchMake(dmp: DiffMatchPatch, out_patches_len: *c_int, mode: c_int, ...) callconv(.c) [*c]Patch {
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
            const diff_int = dmpDiffListFromExtern(allocator, diffs[0..diffs_len]) catch |err| break :blk err;
            break :blk patch.makeDiffs(MatchContainer, allocator, dmp.patch_margin, diff_int);
        },
        3 => blk: {
            const text1: [*c]const u8 = @cVaArg(&ap, [*c]const u8);
            if (text1 == null) break :blk error.NullInputs;
            const diffs: [*c]const Diff = @cVaArg(&ap, [*c]const Diff);
            const diffs_len: usize = @intCast(@cVaArg(&ap, c_int));
            const diff_int = dmpDiffListFromExtern(allocator, diffs[0..diffs_len]) catch |err| break :blk err;
            break :blk patch.makeStringDiffs(MatchContainer, allocator, dmp.patch_margin, std.mem.span(text1), diff_int);
        },
        4 => blk: {
            const text1: [*c]const u8 = @cVaArg(&ap, [*c]const u8);
            const text2: [*c]const u8 = @cVaArg(&ap, [*c]const u8);
            if (text1 == null or text2 == null) break :blk error.NullInputs;
            const diffs: [*c]const Diff = @cVaArg(&ap, [*c]const Diff);
            const diffs_len: usize = @intCast(@cVaArg(&ap, c_int));
            const diff_int = dmpDiffListFromExtern(allocator, diffs[0..diffs_len]) catch |err| break :blk err;
            break :blk patch.makeStringStringDiffs(MatchContainer, allocator, dmp.patch_margin, std.mem.span(text1), std.mem.span(text2), diff_int);
        },
        else => error.InvalidMode,
    } catch |err| {
        callErrorHandled(.function_patch_make, err);
        return null;
    };

    const e_patches = dmpPatchlistToExtern(allocator, res) catch |err| {
        callErrorHandled(.function_patch_make, err);
        return null;
    };
    out_patches_len.* = @intCast(e_patches.len);
    return e_patches.ptr;
}

export fn patchDeepCopy(patches: [*c]const Patch, patches_len: c_int) callconv(.c) [*c]Patch {
    var i_patches = dmpPatchListFromExtern(allocator, patches[0..@intCast(patches_len)]) catch |err| {
        callErrorHandled(.function_patch_deep_copy, err);
        return null;
    };
    defer i_patches.deinit();

    const p_copy = patch.deepCopy(allocator, i_patches) catch |err| {
        callErrorHandled(.function_patch_deep_copy, err);
        return null;
    };

    const o_patches = dmpPatchlistToExtern(allocator, p_copy) catch |err| {
        callErrorHandled(.function_patch_deep_copy, err);
        return null;
    };
    return o_patches.ptr;
}

export fn patchApply(dmp: DiffMatchPatch, patches: [*c]const Patch, patches_len: c_int, text: [*c]const u8, out_applied: *[*c]bool) callconv(.c) [*c]const u8 {
    var i_patches = dmpPatchListFromExtern(allocator, patches[0..@intCast(patches_len)]) catch |err| {
        callErrorHandled(.function_patch_apply, err);
        return null;
    };
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
    ) catch |err| {
        callErrorHandled(.function_patch_apply, err);
        return null;
    };
    out_applied.* = applied.ptr;
    return result.ptr;
}

export fn patchAddPadding(dmp: DiffMatchPatch, patches: [*c]const Patch, patches_len: c_int, out_patches: *[*c]Patch, out_patches_len: *c_int) callconv(.c) [*c]const u8 {
    out_patches_len.* = -1;
    out_patches.* = null;

    var i_patches = dmpPatchListFromExtern(allocator, patches[0..@intCast(patches_len)]) catch |err| {
        callErrorHandled(.function_patch_add_padding, err);
        return null;
    };

    const padding = patch.addPadding(allocator, dmp.patch_margin, &i_patches) catch |err| {
        callErrorHandled(.function_patch_add_padding, err);
        return null;
    };

    const o_patches = dmpPatchlistToExtern(allocator, i_patches) catch |err| {
        callErrorHandled(.function_patch_add_padding, err);
        return null;
    };
    out_patches.* = o_patches.ptr;
    out_patches_len.* = @intCast(o_patches.len);
    return padding.ptr;
}

export fn patchSplitMax(dmp: DiffMatchPatch, patches: [*c]const Patch, patches_len: c_int, out_patches: *[*c]Patch, out_patches_len: *c_int) callconv(.c) c_int {
    out_patches_len.* = -1;
    out_patches.* = null;

    var i_patches = dmpPatchListFromExtern(allocator, patches[0..@intCast(patches_len)]) catch |err| {
        callErrorHandled(.function_patch_split_max, err);
        return -1;
    };

    patch.splitMax(MatchContainer, allocator, dmp.patch_margin, &i_patches) catch |err| {
        callErrorHandled(.function_patch_split_max, err);
        return -1;
    };

    const o_patches = dmpPatchlistToExtern(allocator, i_patches) catch |err| {
        callErrorHandled(.function_patch_split_max, err);
        return -1;
    };
    out_patches.* = o_patches.ptr;
    out_patches_len.* = @intCast(o_patches.len);
    return 0;
}

export fn patchToText(patches: [*c]const Patch, patches_len: c_int) callconv(.c) [*c]const u8 {
    var i_patches = dmpPatchListFromExtern(allocator, patches[0..@intCast(patches_len)]) catch |err| {
        callErrorHandled(.function_patch_to_text, err);
        return null;
    };
    defer i_patches.deinit();

    const text = patch.toText(allocator, i_patches) catch |err| {
        callErrorHandled(.function_patch_to_text, err);
        return null;
    };
    return text.ptr;
}

export fn patchFromText(text: [*c]const u8, out_patches: *[*c]Patch, out_patches_len: *c_int) callconv(.c) c_int {
    out_patches_len.* = -1;
    out_patches.* = null;

    const i_patches = patch.fromText(allocator, std.mem.span(text)) catch |err| {
        callErrorHandled(.function_patch_from_text, err);
        return -1;
    };

    const o_patches = dmpPatchlistToExtern(allocator, i_patches) catch |err| {
        callErrorHandled(.function_patch_from_text, err);
        return -1;
    };
    out_patches.* = o_patches.ptr;
    out_patches_len.* = @intCast(o_patches.len);
    return 0;
}

export fn patchObjToString(p: Patch) callconv(.c) [*c]const u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    var i_patch = dmpPatchFromExtern(allocator, p) catch |err| {
        callErrorHandled(.function_patch_obj_to_string, err);
        return null;
    };
    defer i_patch.deinit(allocator);

    i_patch.format(&writer.writer) catch |err| {
        callErrorHandled(.function_patch_obj_to_string, err);
        return null;
    };
    const text = writer.toOwnedSlice() catch |err| {
        callErrorHandled(.function_patch_obj_to_string, err);
        return null;
    };

    return text.ptr;
}

// utils ---------------

fn dmpDiffListFromExtern(alloc: std.mem.Allocator, diffs: []const Diff) std.mem.Allocator.Error![]diff.Diff {
    const diff_list = try alloc.alloc(diff.Diff, diffs.len);
    for (diffs, diff_list) |d, *nd| {
        nd.* = diff.Diff{ .text = std.mem.span(@constCast(d.text)), .operation = @enumFromInt(@intFromEnum(d.operation)) };
    }
    return diff_list;
}

fn dmpPatchListFromExtern(alloc: std.mem.Allocator, patches: []const Patch) std.mem.Allocator.Error!patch.PatchList {
    var i_patches = try alloc.alloc(patch.Patch, patches.len);
    for (patches, 0..) |p, i| {
        i_patches[i] = try dmpPatchFromExtern(alloc, p);
    }

    return patch.PatchList{
        .allocator = alloc,
        .items = i_patches,
    };
}
fn dmpPatchFromExtern(alloc: std.mem.Allocator, p: Patch) std.mem.Allocator.Error!patch.Patch {
    const diffs = try alloc.alloc(diff.Diff, @intCast(p.diffs_len));
    for (p.diffs[0..@intCast(p.diffs_len)], diffs) |d, *nd| {
        nd.* = .{
            .operation = @enumFromInt(@intFromEnum(d.operation)),
            .text = @constCast(std.mem.span(d.text)),
        };
    }
    return patch.Patch.init(@intCast(p.start1), @intCast(p.start2), @intCast(p.length1), @intCast(p.length2), diffs);
}

fn dmpPatchlistToExtern(alloc: std.mem.Allocator, patchlist: patch.PatchList) std.mem.Allocator.Error![]Patch {
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

fn dmpDifflistToExtern(alloc: std.mem.Allocator, diffs: []diff.Diff) std.mem.Allocator.Error![]Diff {
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
