const std = @import("std");
const diff_funcs = @import("diff.zig");
const Diff = @import("diff.zig").Diff;
const match_funcs = @import("match.zig");
const options = @import("options");
const StrType = options.StrType;

comptime {
    _ = @import("patch_test.zig");
}

const Allocator = std.mem.Allocator;

const utils = @import("utils.zig");

pub const Error = error{
    InvalidPatchMode,
    InvalidPatchString,
};

pub const PatchList = struct {
    items: []Patch,
    allocator: std.mem.Allocator,
    pub fn deinit(self: *const PatchList) void {
        for (self.items) |patch| patch.deinit(self.allocator);
        self.allocator.free(self.items);
        var selfNonConst = @constCast(self);
        selfNonConst = undefined;
    }
};

pub const Patch = struct {
    diffs: []Diff,
    start1: usize,
    start2: usize,
    length1: usize,
    length2: usize,

    ///Emulates GNU diff's format.
    ///Header: @@ -382,8 +481,9 @@
    ///Indices are printed as 1-based, not 0-based.
    pub fn format(
        self: Patch,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("@@ -");

        if (self.length1 == 0) {
            try writer.print("{d},0", .{self.start1});
        } else if (self.length1 == 1) {
            try writer.print("{d}", .{self.start1 + 1});
        } else {
            try writer.print("{d},{d}", .{ self.start1 + 1, self.length1 });
        }

        try writer.writeAll(" +");

        if (self.length2 == 0) {
            try writer.print("{d},0", .{self.start2});
        } else if (self.length2 == 1) {
            try writer.print("{d}", .{self.start2 + 1});
        } else {
            try writer.print("{d},{d}", .{ self.start2 + 1, self.length2 });
        }

        try writer.writeAll(" @@\n");

        // Escape the body of the patch with %xx notation.
        for (self.diffs) |diff| {
            switch (diff.operation) {
                .insert => try writer.writeAll("+"),
                .delete => try writer.writeAll("-"),
                .equal => try writer.writeAll(" "),
            }

            try utils.encodeURI(writer, diff.text);
            try writer.writeAll("\n");
        }
    }

    pub fn init(start1: usize, start2: usize, length1: usize, length2: usize, diffs: []Diff) Patch {
        return Patch{
            .start1 = start1,
            .start2 = start2,
            .length1 = length1,
            .length2 = length2,
            .diffs = diffs,
        };
    }

    pub fn deinit(self: *const Patch, allocator: std.mem.Allocator) void {
        for (self.diffs) |diff| diff.deinit(allocator);
        allocator.free(self.diffs);
        var selfNonConst = @constCast(self);
        selfNonConst = undefined;
    }
};

///Increase the context until it is unique,
///but don't let the pattern expand beyond match_max_bits.
pub fn addContext(comptime MatchMaxContainer: type, allocator: Allocator, patch_margin: u16, patch: *Patch, text: []const u8) Allocator.Error!void {
    const match_max_bits = @bitSizeOf(MatchMaxContainer);

    if (text.len == 0) return;

    var pattern = text[patch.start2 .. patch.start2 + patch.length1];
    var padding: usize = 0;

    // Look for the first and last matches of pattern in text. If two different
    // matches are found, increase the pattern length.
    while (std.mem.indexOf(u8, text, pattern) != std.mem.lastIndexOf(u8, text, pattern) and
        pattern.len < match_max_bits - 2 * patch_margin)
    {
        padding += patch_margin;
        const pattern_start = patch.start2 -| padding;
        const pattern_end = @min(text.len, patch.start2 + patch.length1 + padding);
        pattern = text[pattern_start..pattern_end];
    }
    padding += patch_margin;

    // add the prefix
    const prefix_start = patch.start2 -| padding;
    const prefix_end = patch.start2;
    const prefix = text[prefix_start..prefix_end];

    // add the suffix
    const suffix_start = patch.start2 + patch.length1;
    const suffix_end = @min(text.len, patch.start2 + patch.length1 + padding);
    const suffix = text[suffix_start..suffix_end];

    {
        var new_len = patch.diffs.len;
        new_len += if (prefix.len != 0) 1 else 0;
        new_len += if (suffix.len != 0) 1 else 0;
        _ = try utils.resize(Diff, allocator, &patch.diffs, new_len);

        if (prefix.len != 0) {
            std.mem.copyBackwards(Diff, patch.diffs[1..], patch.diffs[0 .. patch.diffs.len - 1]);
            patch.diffs[0] = try Diff.fromSlice(allocator, prefix, .equal);
        }
        if (suffix.len != 0) {
            patch.diffs[patch.diffs.len - 1] = try Diff.fromSlice(allocator, suffix, .equal);
        }
    }

    // Roll back the start points.
    patch.start1 -= prefix.len;
    patch.start2 -= prefix.len;
    // Extend the lengths.
    patch.length1 += prefix.len + suffix.len;
    patch.length2 += prefix.len + suffix.len;
}

// patch make parts
///Compute a list of patches to turn text1 into text2.
///A set of diffs will be computed.
pub fn makeStringString(comptime MatchMaxContainer: type, allocator: Allocator, patch_margin: u16, diff_edit_cost: u16, diff_timeout: f32, text1: []const u8, text2: []const u8) error{ OutOfMemory, InvalidUtf8 }!PatchList {
    var diffs = try diff_funcs.mainStringStringBool(allocator, diff_timeout, text1, text2, true);
    defer allocator.free(diffs);
    errdefer for (diffs) |diff| diff.deinit(allocator);
    if (diffs.len > 2) {
        try diff_funcs.cleanupSemantic(allocator, &diffs);
        try diff_funcs.cleanupEfficiency(allocator, diff_edit_cost, &diffs);
    }

    return makeStringDiffs(MatchMaxContainer, allocator, patch_margin, text1, diffs);
}

///Compute a list of patches to turn text1 into text2.
///text1 will be derived from the provided diffs.
pub fn makeDiffs(comptime MatchMaxContainer: type, allocator: Allocator, patch_margin: u16, diffs: []const Diff) !PatchList {
    const text1 = try diff_funcs.text1(allocator, diffs);
    defer allocator.free(text1);
    return makeStringDiffs(MatchMaxContainer, allocator, patch_margin, text1, diffs);
}

///Compute a list of patches to turn text1 into text2.
///text2 is ignored, diffs are the delta between text1 and text2.
///Depricated, use patchStringDiffs
pub fn makeStringStringDiffs(
    comptime MatchMaxContainer: type,
    allocator: Allocator,
    patch_margin: u16,
    text1: []const u8,
    text2: []const u8,
    diffs: []const Diff,
) !PatchList {
    _ = text2;
    return makeStringDiffs(MatchMaxContainer, allocator, patch_margin, text1, diffs);
}

///Compute a list of patches to turn text1 into text2.
///text2 is not provided, diffs are the delta between text1 and text2.
pub fn makeStringDiffs(
    comptime MatchMaxContainer: type,
    allocator: Allocator,
    patch_margin: u16,
    text1: []const u8,
    diffs: []const Diff,
) Allocator.Error!PatchList {
    var patches: std.ArrayList(Patch) = .{};
    defer patches.deinit(allocator);
    if (diffs.len == 0) {
        return .{ .items = try patches.toOwnedSlice(allocator), .allocator = allocator };
    }

    var patch = Patch.init(0, 0, 0, 0, undefined);

    var patch_diffs = try allocator.alloc(Diff, diffs.len);
    // errdefer allocator.free(patch_diffs);
    var patch_diffs_ptr: usize = 0;

    var char_count1: usize = 0; // Number of characters into the text1 string.
    var char_count2: usize = 0; // Number of characters into the text2 string.

    // Start with text1 (prepatch_text) and apply the diffs until we arrive at
    // text2 (postpatch_text). We recreate the patches one by one to determine
    // context info.
    var prepatch_text = try std.ArrayList(u8).initCapacity(allocator, text1.len);
    defer prepatch_text.deinit(allocator);
    try prepatch_text.appendSlice(allocator, text1);

    var postpatch_text = try std.ArrayList(u8).initCapacity(allocator, text1.len);
    defer postpatch_text.deinit(allocator);
    try postpatch_text.appendSlice(allocator, text1);

    for (diffs, 0..) |diff, loc| {
        if (patch_diffs_ptr == 0 and diff.operation != .equal) {
            // new patch starts here
            patch.start1 = char_count1;
            patch.start2 = char_count2;
        }

        switch (diff.operation) {
            .insert => {
                patch_diffs[patch_diffs_ptr] = diff;
                patch_diffs_ptr += 1;

                patch.length2 += diff.text.len;
                try postpatch_text.insertSlice(allocator, char_count2, diff.text);
            },
            .delete => {
                patch.length1 += diff.text.len;
                try postpatch_text.replaceRange(allocator, char_count2, diff.text.len, &.{});

                patch_diffs[patch_diffs_ptr] = diff;
                patch_diffs_ptr += 1;
            },
            .equal => {
                if (diff.text.len <= 2 * patch_margin and
                    patch_diffs_ptr != 0 and loc != diffs.len - 1)
                {
                    // Small equality inside a patch.
                    patch_diffs[patch_diffs_ptr] = diff;
                    patch_diffs_ptr += 1;

                    patch.length1 += diff.text.len;
                    patch.length2 += diff.text.len;
                } else {
                    allocator.free(diff.text);
                }

                if (diff.text.len >= 2 * patch_margin) {
                    // Time for a new patch.
                    if (patch_diffs_ptr != 0) {
                        _ = try utils.resize(Diff, allocator, &patch_diffs, patch_diffs_ptr);
                        patch.diffs = patch_diffs;

                        try addContext(MatchMaxContainer, allocator, patch_margin, &patch, prepatch_text.items);
                        try patches.append(allocator, patch);

                        patch = Patch.init(0, 0, 0, 0, undefined);
                        patch_diffs_ptr = 0;
                        patch_diffs = try allocator.alloc(Diff, diffs.len - (loc + 1));

                        // Unlike Unidiff, our patch lists have a rolling context.
                        // http://code.google.com/p/google-diff-match-patch/wiki/Unidiff
                        // Update prepatch text & pos to reflect the application of the
                        // just completed patch.
                        prepatch_text.clearRetainingCapacity();
                        try prepatch_text.appendSlice(allocator, postpatch_text.items);
                        char_count1 = char_count2;
                    }
                }
            },
        }

        // Update the current character count.
        if (diff.operation != .insert) {
            char_count1 += diff.text.len;
        }
        if (diff.operation != .delete) {
            char_count2 += diff.text.len;
        }
    }
    // Pick up the leftover patch if not empty.
    if (patch_diffs_ptr != 0) {
        _ = try utils.resize(Diff, allocator, &patch_diffs, patch_diffs_ptr);
        patch.diffs = patch_diffs;

        try addContext(MatchMaxContainer, allocator, patch_margin, &patch, prepatch_text.items);
        try patches.append(allocator, patch);
    } else {
        patch.diffs = patch_diffs; // to free together
        patch.deinit(allocator);
    }

    return .{ .items = try patches.toOwnedSlice(allocator), .allocator = allocator };
}

///Given an array of patches, return another array that is identical.
pub fn deepCopy(allocator: Allocator, patches: PatchList) Allocator.Error!PatchList {
    const patches_copy = try allocator.alloc(Patch, patches.items.len);
    errdefer allocator.free(patches_copy);
    for (patches.items, patches_copy) |patch, *patch_copy| {
        const diffs = try allocator.alloc(Diff, patch.diffs.len);
        errdefer allocator.free(diffs);
        for (patch.diffs, diffs) |diff, *diff_copy| {
            diff_copy.* = try Diff.fromSlice(allocator, diff.text, diff.operation); // NOTE: all the allocated ones wont get freed on an error
        }

        patch_copy.* = Patch.init(patch.start1, patch.start2, patch.length1, patch.length2, diffs);
        errdefer patch_copy.deinit(allocator);
    }
    return .{ .items = patches_copy, .allocator = allocator };
}

///Merge a set of patches onto the text.  Return a patched text, as well
///as an array of true/false values indicating which patches were applied.
pub fn apply(
    comptime MatchMaxContainer: type,
    allocator: Allocator,
    diff_timeout: f32,
    match_distance: u32,
    match_threshold: f32,
    patch_margin: u16,
    patch_delete_threshold: f32,
    patches: PatchList,
    text: []const u8,
) (match_funcs.MatchError || Allocator.Error || std.Io.Writer.Error || error{InvalidUtf8})!struct { []const u8, []const bool } {
    const match_max_bits = @bitSizeOf(MatchMaxContainer);

    if (patches.items.len == 0) {
        const result = try allocator.alloc(u8, text.len);
        @memcpy(result, text);
        return .{ result, try allocator.alloc(bool, 0) };
    }

    // Deep copy the patches so that no changes are made to originals.
    var patchesCopy = try deepCopy(allocator, patches);
    defer patchesCopy.deinit();

    const null_padding = try addPadding(allocator, patch_margin, &patchesCopy);
    defer allocator.free(null_padding);

    var working_text_writer = try std.Io.Writer.Allocating.initCapacity(allocator, text.len + 2 * null_padding.len);
    var working_text: std.ArrayList(u8) = undefined;
    {
        defer working_text_writer.deinit();
        try working_text_writer.writer.writeAll(null_padding);
        try std.unicode.fmtUtf8(text).format(&working_text_writer.writer);
        // try working_text_writer.writer.writeAll(text);
        try working_text_writer.writer.writeAll(null_padding);
        working_text = working_text_writer.toArrayList();
    }
    defer working_text.deinit(allocator);

    try splitMax(MatchMaxContainer, allocator, patch_margin, &patchesCopy);

    var applied = try allocator.alloc(bool, patchesCopy.items.len);
    errdefer allocator.free(applied);

    var x: usize = 0;
    // delta keeps track of the offset between the expected and actual location
    // of the previous patch.  If there are patches expected at positions 10 and
    // 20, but the first patch was found at 12, delta is 2 and the second patch
    // has an effective expected position of 22.
    var delta: isize = 0;
    for (patchesCopy.items) |patch| {
        const expected_loc: usize = @intCast(@as(isize, @intCast(patch.start2)) + delta);

        const text1 = try diff_funcs.text1(allocator, patch.diffs);
        defer allocator.free(text1);

        var start_loc: ?usize = null;
        var end_loc: ?usize = null;
        if (text1.len > match_max_bits) {
            // `patchSplitMax` will only provide an oversized pattern in the case of
            // a monster delete.
            start_loc = try match_funcs.main(MatchMaxContainer, allocator, match_distance, match_threshold, working_text.items, text1[0..match_max_bits], expected_loc);
            if (start_loc != null) {
                end_loc = try match_funcs.main(MatchMaxContainer, allocator, match_distance, match_threshold, working_text.items, text1[text1.len - match_max_bits ..], expected_loc + text1.len - match_max_bits);
                if (end_loc == null or start_loc.? >= end_loc.?) {
                    // Can't find valid trailing context.  Drop this patch.
                    start_loc = null;
                }
            }
        } else {
            start_loc = try match_funcs.main(MatchMaxContainer, allocator, match_distance, match_threshold, working_text.items, text1, expected_loc);
        }
        if (start_loc == null) {
            // No match found.  :(
            applied[x] = false;
            // Subtract the delta for this failed patch from subsequent patches.
            delta -= @as(isize, @intCast(patch.length2)) - @as(isize, @intCast(patch.length1));
        } else {
            // Found a match.  :)
            applied[x] = true;
            delta = @as(isize, @intCast(start_loc.?)) - @as(isize, @intCast(expected_loc));

            var text2: []const u8 = undefined;
            if (end_loc == null) {
                text2 = working_text.items[start_loc.?..@min(start_loc.? + text1.len, working_text.items.len)];
            } else {
                text2 = working_text.items[start_loc.?..@min(end_loc.? + match_max_bits, working_text.items.len)];
            }

            if (std.mem.eql(u8, text1, text2)) {
                // Perfect match, just shove the Replacement text in.
                const replacement = try diff_funcs.text2(allocator, patch.diffs);
                defer allocator.free(replacement);
                try working_text.replaceRange(allocator, start_loc.?, text1.len, replacement);
            } else {
                // Imperfect match.  Run a diff to get a framework of equivalent indices.
                var diffs = try diff_funcs.mainStringStringBool(allocator, diff_timeout, text1, text2, false);
                defer allocator.free(diffs);
                defer for (diffs) |diff| diff.deinit(allocator);

                if (text1.len > match_max_bits and
                    @as(f64, @floatFromInt(diff_funcs.levenshtein(diffs))) / @as(f64, @floatFromInt(text1.len)) > patch_delete_threshold)
                {
                    // The end points match, but the content is unacceptably bad.
                    applied[x] = false;
                } else {
                    try diff_funcs.cleanupSemanticLossless(allocator, &diffs);
                    var index1: usize = 0;
                    for (patch.diffs) |diff| {
                        if (diff.operation != .equal) blk: {
                            const index2 = diff_funcs.xIndex(diffs, index1);
                            if (diff.operation == .insert) {
                                // Insertion
                                try working_text.insertSlice(allocator, start_loc.? + index2, diff.text);
                                break :blk;
                            }
                            std.debug.assert(diff.operation == .delete);
                            // Deletion

                            const rem_len = diff_funcs.xIndex(diffs, index1 + diff.text.len);
                            std.debug.assert(rem_len > index2);
                            working_text.replaceRangeAssumeCapacity(start_loc.? + index2, rem_len - index2, &.{});
                        }
                        if (diff.operation != .delete) {
                            index1 += diff.text.len;
                        }
                    }
                }
            }
        }
        x += 1;
    }
    // Strip the padding off.
    const new_len = working_text.items.len - 2 * null_padding.len;
    std.mem.copyForwards(
        u8,
        working_text.items[0..new_len],
        working_text.items[null_padding.len .. working_text.items.len - null_padding.len],
    );
    working_text.items.len = new_len;
    return .{ try working_text.toOwnedSlice(allocator), applied };
}

///Add some padding on text start and end so that edges can match something.
///Intended to be called only from within `patchApply`.
pub fn addPadding(allocator: Allocator, patch_margin: u16, patches: *PatchList) Allocator.Error!StrType {
    const padding_length = patch_margin;
    const null_padding = if (options.nullTerminated)
        try allocator.allocSentinel(u8, padding_length, 0)
    else
        try allocator.alloc(u8, padding_length);
    for (0..padding_length) |i| {
        null_padding[i] = @intCast(i + 1);
    }

    // Bump all the patches forward.
    for (patches.items) |*patch| {
        patch.start1 += padding_length;
        patch.start2 += padding_length;
    }

    // Add some padding on start of first diff.
    if (patches.items[0].diffs.len == 0 or patches.items[0].diffs[0].operation != .equal) {
        // Add null_padding equality.
        const old_len = try utils.resize(Diff, allocator, &patches.items[0].diffs, patches.items[0].diffs.len + 1);
        std.mem.copyBackwards(Diff, patches.items[0].diffs[1..], patches.items[0].diffs[0..old_len]);
        patches.items[0].diffs[0] = try Diff.fromSlice(allocator, null_padding, .equal);

        patches.items[0].start1 -= padding_length; // Should be 0.
        patches.items[0].start2 -= padding_length; // Should be 0.
        patches.items[0].length1 += padding_length;
        patches.items[0].length2 += padding_length;
    } else if (padding_length > patches.items[0].diffs[0].text.len) {
        // Grow first equality.
        const extra_length = padding_length - patches.items[0].diffs[0].text.len;
        const old_len = try utils.resize(u8, allocator, &patches.items[0].diffs[0].text, padding_length);

        std.mem.copyBackwards(u8, patches.items[0].diffs[0].text[extra_length..], patches.items[0].diffs[0].text[0..old_len]);
        @memcpy(patches.items[0].diffs[0].text[0..extra_length], null_padding[old_len..]);

        patches.items[0].start1 -= extra_length;
        patches.items[0].start2 -= extra_length;
        patches.items[0].length1 += extra_length;
        patches.items[0].length2 += extra_length;
    }

    // Add some padding on end of last diff.
    const last_idx = patches.items.len - 1;
    if (patches.items[last_idx].diffs.len == 0 or
        patches.items[last_idx].diffs[patches.items[last_idx].diffs.len - 1].operation != .equal)
    {
        // Add nullPadding equality.
        _ = try utils.resize(Diff, allocator, &patches.items[last_idx].diffs, patches.items[last_idx].diffs.len + 1);
        patches.items[last_idx].diffs[patches.items[last_idx].diffs.len - 1] = try Diff.fromSlice(allocator, null_padding, .equal);

        patches.items[last_idx].length1 += padding_length;
        patches.items[last_idx].length2 += padding_length;
    } else if (padding_length > patches.items[last_idx].diffs[patches.items[last_idx].diffs.len - 1].text.len) {
        // Grow last equality.
        const extra_length = padding_length - patches.items[last_idx].diffs[patches.items[last_idx].diffs.len - 1].text.len;

        _ = try utils.resize(
            u8,
            allocator,
            &patches.items[last_idx].diffs[patches.items[last_idx].diffs.len - 1].text,
            padding_length,
        );
        std.mem.copyForwards(
            u8,
            patches.items[last_idx].diffs[patches.items[last_idx].diffs.len - 1].text[padding_length - extra_length ..],
            null_padding[0..extra_length],
        );

        patches.items[last_idx].length1 += extra_length;
        patches.items[last_idx].length2 += extra_length;
    }

    return null_padding;
}

///Look through the patches and break up any which are longer than the
///maximum limit of the match algorithm.
///Intended to be called only from within `patchApply`.
pub fn splitMax(comptime MatchMaxContainer: type, allocator: Allocator, patch_margin: u16, patches: *PatchList) !void {
    const patch_size = @bitSizeOf(MatchMaxContainer);

    var precontext = try std.ArrayList(u8).initCapacity(allocator, patch_margin);
    defer precontext.deinit(allocator);
    var postcontext: []const u8 = undefined;

    var patchlist = std.ArrayList(Patch).fromOwnedSlice(patches.items);
    defer patchlist.deinit(allocator);

    var x: ?usize = 0;
    while (utils.getIdxOrNull(Patch, patchlist, x.?)) |big_patch| {
        defer if (x == null) {
            x = 0;
        } else {
            x = x.? + 1;
        };

        if (big_patch.length1 <= patch_size) continue;

        var big_diffs_ptr: usize = 0;
        // Remove the big old patch.
        _ = patchlist.orderedRemove(x.?);
        defer {
            for (big_patch.diffs[big_diffs_ptr..]) |diff| diff.deinit(allocator);
            allocator.free(big_patch.diffs);
        }

        if (x.? > 0) {
            x = x.? - 1;
        } else {
            x = null;
        }

        var start1 = big_patch.start1;
        var start2 = big_patch.start2;
        precontext.clearRetainingCapacity();
        while ((big_patch.diffs.len - big_diffs_ptr) != 0) {
            // Create one of several smaller patches.
            var patch = Patch.init(
                start1 - precontext.items.len,
                start2 - precontext.items.len,
                0,
                0,
                undefined,
            );
            // NOTE: doing 2 allocs, one with the full size (- what was used) and one to resize
            //       rather then doing an alloc every time to append
            var diffs = try allocator.alloc(Diff, big_patch.diffs.len - big_diffs_ptr);
            var diff_ptr: usize = 0;

            var empty = true;
            if (precontext.items.len != 0) {
                patch.length1 = precontext.items.len;
                patch.length2 = precontext.items.len;
                diffs[diff_ptr] = try Diff.fromSlice(allocator, precontext.items, .equal);
                diff_ptr += 1;
            }
            while ((big_patch.diffs.len - big_diffs_ptr) != 0 and
                patch.length1 < patch_size - patch_margin)
            {
                const diff_type = big_patch.diffs[big_diffs_ptr].operation;
                var diff_text = big_patch.diffs[big_diffs_ptr].text;
                if (diff_type == .insert) {
                    // Insertions are harmless.
                    patch.length2 += diff_text.len;
                    start2 += diff_text.len;

                    diffs[diff_ptr] = big_patch.diffs[big_diffs_ptr];
                    diff_ptr += 1;
                    big_diffs_ptr += 1;

                    empty = false;
                } else if (diff_type == .delete and
                    diff_ptr == 1 and
                    diffs[0].operation == .equal and
                    diff_text.len > 2 * patch_size)
                {
                    // This is a large deletion.  Let it pass in one chunk.
                    patch.length1 += diff_text.len;
                    start1 += diff_text.len;

                    diffs[diff_ptr] = big_patch.diffs[big_diffs_ptr];
                    diff_ptr += 1;
                    big_diffs_ptr += 1;

                    empty = false;
                } else {
                    // Deletion or equality.  Only take as much as we can stomach.
                    const diff_text_len = @min(
                        diff_text.len,
                        patch_size - patch.length1 - patch_margin,
                    );
                    diff_text = diff_text[0..diff_text_len];

                    patch.length1 += diff_text_len;
                    start1 += diff_text_len;
                    if (diff_type == .equal) {
                        patch.length2 += diff_text_len;
                        start2 += diff_text_len;
                    } else {
                        empty = false;
                    }

                    // have to do a resize to make more room
                    _ = try utils.resize(Diff, allocator, &diffs, diffs.len + 1);
                    diffs[diff_ptr] = try Diff.fromSlice(allocator, diff_text, diff_type);
                    diff_ptr += 1;

                    if (std.mem.eql(u8, diff_text, big_patch.diffs[big_diffs_ptr].text)) {
                        big_patch.diffs[big_diffs_ptr].deinit(allocator);
                        big_diffs_ptr += 1;
                    } else {
                        const len = big_patch.diffs[big_diffs_ptr].text.len - diff_text_len;
                        std.mem.copyForwards(
                            u8,
                            big_patch.diffs[big_diffs_ptr].text[0..len],
                            big_patch.diffs[big_diffs_ptr].text[diff_text_len..],
                        );
                        _ = try utils.resize(
                            u8,
                            allocator,
                            &big_patch.diffs[big_diffs_ptr].text,
                            len,
                        );
                    }
                }
            }
            // Compute the head context for the next patch.
            {
                const text2 = try diff_funcs.text2(allocator, diffs[0..diff_ptr]);
                defer allocator.free(text2);

                precontext.clearRetainingCapacity(); // TODO: see if can be done with less allocs
                try precontext.appendSlice(allocator, if (text2.len <= patch_margin)
                    text2
                else
                    text2[text2.len - patch_margin ..]);
            }

            postcontext = undefined;
            // Append the end context for this patch.
            const dt1 = try diff_funcs.text1(allocator, big_patch.diffs[big_diffs_ptr..]);
            defer allocator.free(dt1);
            if (dt1.len > patch_margin) {
                postcontext = dt1[0..patch_margin];
            } else {
                postcontext = dt1;
            }

            if (postcontext.len != 0) {
                patch.length1 += postcontext.len;
                patch.length2 += postcontext.len;
                if (diff_ptr != 0 and
                    diffs[diff_ptr - 1].operation == .equal)
                {
                    const old_len = try utils.resize(
                        u8,
                        allocator,
                        &diffs[diff_ptr - 1].text,
                        diffs[diff_ptr - 1].text.len + postcontext.len,
                    );
                    std.mem.copyForwards(u8, diffs[diff_ptr - 1].text[old_len..], postcontext);
                } else {
                    diffs[diff_ptr] = try Diff.fromSlice(allocator, postcontext, .equal);
                    diff_ptr += 1;
                }
            }

            if (empty) {
                patch.diffs = diffs; // to dealocated it in the deinit call below all together
                patch.deinit(allocator);
            } else {
                // resize to correct size
                _ = try utils.resize(Diff, allocator, &diffs, diff_ptr);
                patch.diffs = diffs;

                x = if (x == null) 0 else x.? + 1;
                try patchlist.insert(allocator, x.?, patch);
            }
        }
    }

    patches.items = try patchlist.toOwnedSlice(allocator);
}

///Take a list of patches and return a textual representation.
pub fn toText(allocator: Allocator, patches: PatchList) !StrType {
    var text = std.Io.Writer.Allocating.init(allocator);
    defer text.deinit();
    for (patches.items) |patch| {
        try patch.format(&text.writer);
    }
    if (options.nullTerminated)
        return text.toOwnedSliceSentinel(0)
    else
        return text.toOwnedSlice();
}

///Parse a textual representation of patches and return a List of Patch objects.
pub fn fromText(allocator: Allocator, textline: []const u8) (Error || Allocator.Error)!PatchList {
    var patches: std.ArrayList(Patch) = .{};
    defer patches.deinit(allocator);
    errdefer for (patches.items) |patch| patch.deinit(allocator);

    if (textline.len == 0) {
        return .{ .items = try patches.toOwnedSlice(allocator), .allocator = allocator };
    }

    var patch: Patch = undefined;

    var texts = std.mem.splitScalar(u8, textline, '\n');
    while (texts.next()) |text| {
        const header = utils.matchPatchHeader(text) orelse return Error.InvalidPatchString;

        patch = Patch.init(header[0], header[2], undefined, undefined, undefined);
        errdefer patch.deinit(allocator);
        if (header[1] == 0) {
            patch.length1 = 0;
        } else {
            patch.start1 -= 1;
            patch.length1 = header[1] orelse 1;
        }

        if (header[3] == 0) {
            patch.length2 = 0;
        } else {
            patch.start2 -= 1;
            patch.length2 = header[3] orelse 1;
        }

        const diffs_len = blk: {
            var parts = std.mem.splitScalar(u8, texts.rest(), '\n');
            var len: usize = 0;
            while (parts.next()) |line| {
                if (line.len == 0) continue;
                switch (line[0]) {
                    '-', '+', ' ' => len += 1,
                    '@' => break,
                    else => return error.InvalidPatchMode, // WTF?
                }
            }
            break :blk len;
        };

        const diffs = try allocator.alloc(Diff, diffs_len);
        errdefer allocator.free(diffs);
        var diffs_ptr: usize = 0;

        while (texts.next()) |change| {
            if (change.len == 0) continue;

            const line_encoded = try allocator.alloc(u8, change.len - 1);
            defer allocator.free(line_encoded);
            @memcpy(line_encoded, change[1..]);

            const line = std.Uri.percentDecodeInPlace(line_encoded);
            std.debug.assert(std.unicode.utf8ValidateSlice(line));

            switch (change[0]) {
                '-' => {
                    // Deletion.
                    diffs[diffs_ptr] = try Diff.fromSlice(allocator, line, .delete);
                    diffs_ptr += 1;
                },
                '+' => {
                    // Insertion.
                    diffs[diffs_ptr] = try Diff.fromSlice(allocator, line, .insert);
                    diffs_ptr += 1;
                },
                ' ' => {
                    // Minor equality.
                    diffs[diffs_ptr] = try Diff.fromSlice(allocator, line, .equal);
                    diffs_ptr += 1;
                },
                '@' => {
                    // Start of next patch.
                    // walk back index
                    texts.index = (texts.index orelse texts.buffer.len) - text.len - 1;
                    break;
                },
                else => unreachable,
            }
        }
        std.debug.assert(diffs_ptr == diffs.len);
        patch.diffs = diffs;
        try patches.append(allocator, patch);
    }
    return .{ .items = try patches.toOwnedSlice(allocator), .allocator = allocator };
}
