const std = @import("std");
const utils = @import("utils.zig");
const options = @import("options");
const StrType = options.StrType;

comptime {
    _ = @import("diff_test.zig");
}

// TODO: user more of array list instead of going back and forth
// TODO: make a deinit function for list
// TODO: for zig centric implementation, wrap types in enums, to allow defaults and stop from passing wrong type of value

const Allocator = std.mem.Allocator;

const DiffPrivate = @import("diff_private.zig");

pub const diff_max_duration = std.math.maxInt(u64);

pub const Error = error{
    DeltaContainsIlligalOperation,
    DeltaContainsInvalidUTF8,
    DeltaBadNumber,
    DeltaContainsNegetiveNumber,
    DeltaLongerThenSource,
    DeltaShorterThenSource,
};

pub const Diff = struct {
    pub const Operation = enum(i2) {
        delete = -1,
        equal = 0,
        insert = 1,
    };

    operation: Operation,
    text: []u8,

    pub fn fromSlice(allocator: std.mem.Allocator, text: []const u8, operation: Diff.Operation) std.mem.Allocator.Error!Diff {
        const owned_text = try allocator.alloc(u8, text.len);
        @memcpy(owned_text.ptr, text);
        return .{
            .text = owned_text,
            .operation = operation,
        };
    }

    pub fn deinit(self: *const Diff, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        var selfNonConst = @constCast(self);
        selfNonConst = undefined;
    }
};

pub fn deinitDiffList(allocator: std.mem.Allocator, diffs: []const Diff) void {
    for (diffs) |e| e.deinit(allocator);
    allocator.free(diffs);
}

///Find the differences between two texts.
///Run a faster, slightly less optimal diff.
///This method allows the 'checklines' of `diffMainStringStringBool` to be optional.
///Most of the time checklines is wanted, so default to true.
pub fn mainStringString(allocator: Allocator, diff_timeout: f32, text_a: []const u8, text_b: []const u8) ![]Diff {
    return mainStringStringBool(allocator, diff_timeout, text_a, text_b, true);
}

///Find the differences between two texts.
pub fn mainStringStringBool(allocator: Allocator, diff_timeout: f32, text_a: []const u8, text_b: []const u8, check_lines: bool) ![]Diff {
    var deadline: u64 = undefined;
    if (diff_timeout > 0) {
        deadline = @intFromFloat(diff_timeout * std.time.ns_per_s);
    } else {
        deadline = diff_max_duration;
    }
    return DiffPrivate.mainStringStringBoolTimeout(allocator, diff_timeout, text_a, text_b, check_lines, deadline);
}

///Determine the common prefix of two strings.
pub fn commonPrefix(text_a: []const u8, text_b: []const u8) usize {
    std.debug.assert(std.unicode.utf8ValidateSlice(text_a));
    std.debug.assert(std.unicode.utf8ValidateSlice(text_b));

    var itr1 = std.unicode.Utf8View.initUnchecked(text_a).iterator();
    var itr2 = std.unicode.Utf8View.initUnchecked(text_b).iterator();

    var len: usize = 0;
    while (true) {
        const c1 = itr1.nextCodepoint() orelse break;
        const c2 = itr2.nextCodepoint() orelse break;
        if (c1 != c2) break;
        len = itr1.i;
    }
    return len;
}

///Determine the common suffix of two strings.
pub fn commonSuffix(text_a: []const u8, text_b: []const u8) usize {
    std.debug.assert(std.unicode.utf8ValidateSlice(text_a));
    std.debug.assert(std.unicode.utf8ValidateSlice(text_b));

    var itr1 = utils.initUtf8BackwardsIterator(text_a);
    var itr2 = utils.initUtf8BackwardsIterator(text_b);

    var len: usize = 0;
    while (true) {
        const c1 = itr1.nextCodepoint() orelse break;
        const c2 = itr2.nextCodepoint() orelse break;
        if (c1 != c2) break;
        len += std.unicode.utf8CodepointSequenceLength(c1) catch unreachable;
    }
    return len;
}

///Reduce the number of edits by eliminating semantically trivial equalities.
pub fn cleanupSemantic(allocator: Allocator, diffs: *[]Diff) Allocator.Error!void {
    if (diffs.len == 0) return;
    var diff_list = std.ArrayList(Diff).fromOwnedSlice(diffs.*);
    defer diff_list.deinit(allocator);
    errdefer if (diff_list.toOwnedSlice(allocator)) |diff_o| {
        diffs.* = diff_o;
    } else |_| {};

    var changes = false;

    // Stack of indices where equalities are found.
    var equalities = try std.ArrayList(usize).initCapacity(allocator, diffs.len);
    defer equalities.deinit(allocator);

    var pointer: usize = 0;
    var last_equality: ?[]const u8 = null;

    // Number of characters that changed prior to the equality.
    var length_insertions1: usize = 0;
    var length_deletions1: usize = 0;

    // Number of characters that changed after the equality.
    var length_insertions2: usize = 0;
    var length_deletions2: usize = 0;

    while (pointer < diff_list.items.len) {
        const diff = diff_list.items[pointer];
        if (diff.operation == .equal) {
            // Equalitfound.
            equalities.appendAssumeCapacity(pointer);
            length_insertions1 = length_insertions2;
            length_deletions1 = length_deletions2;
            length_insertions2 = 0;
            length_deletions2 = 0;
            last_equality = diff.text;

            pointer += 1;
            continue;
        }

        std.debug.assert(std.unicode.utf8ValidateSlice(diff.text)); // TODO: make better, maybe decode?
        // An insertion or deletion.
        if (diff.operation == .insert) {
            length_insertions2 += std.unicode.utf8CountCodepoints(diff.text) catch unreachable;
        } else {
            length_deletions2 += std.unicode.utf8CountCodepoints(diff.text) catch unreachable;
        }

        // Eliminate an equality that is smaller or equal to the edits on both sides of it.
        const difference1 = @max(length_insertions1, length_deletions1);
        const difference2 = @max(length_insertions2, length_deletions2);

        if (blk: {
            if (last_equality == null) break :blk false;
            std.debug.assert(std.unicode.utf8ValidateSlice(diff.text));
            const last_equality_count = std.unicode.utf8CountCodepoints(last_equality.?) catch unreachable;
            break :blk last_equality_count <= difference1 and last_equality_count <= difference2;
        }) {
            // Duplicate record
            try diff_list.insert(allocator, equalities.getLast(), try Diff.fromSlice(allocator, last_equality.?, .delete));

            // Change second copy to insert.
            diff_list.items[equalities.getLast() + 1].operation = .insert;
            // Thow away the equality that was deleted.
            equalities.items.len -= 1;

            if (equalities.items.len > 0) {
                // Throw away the previous equality (it needs to be reevaluated).
                equalities.items.len -= 1;
            }

            if (equalities.items.len > 0) {
                pointer = equalities.getLast() + 1;
            } else {
                pointer = 0;
            }

            // reset the counters
            length_insertions1 = 0;
            length_deletions1 = 0;
            length_insertions2 = 0;
            length_deletions2 = 0;
            last_equality = null;
            changes = true;
            continue;
        }

        pointer += 1;
    }

    // Normalize the diff.
    diffs.* = try diff_list.toOwnedSlice(allocator);
    if (changes) {
        try cleanupMerge(allocator, diffs);
    }
    try cleanupSemanticLossless(allocator, diffs);
    diff_list.capacity = diffs.len;
    diff_list.items = diffs.*;

    // Find any overlaps between deletions and insertions.
    // e.g: <del>abcxxx</del><ins>xxxdef</ins>
    //   -> <del>abc</del>xxx<ins>def</ins>
    // e.g: <del>xxxabc</del><ins>defxxx</ins>
    //   -> <ins>def</ins>xxx<del>abc</del>
    // Only extract an overlap if it is as big as the edit ahead or behind it.
    pointer = 1;
    while (pointer < diff_list.items.len) {
        var last_diff = diff_list.items[pointer - 1];
        var diff = diff_list.items[pointer];
        if (last_diff.operation == .delete and diff.operation == .insert) {
            const overlap_length1 = DiffPrivate.commonOverlap(last_diff.text, diff.text);
            const overlap_length2 = DiffPrivate.commonOverlap(diff.text, last_diff.text);
            if (overlap_length1 >= overlap_length2) {
                std.debug.assert(std.unicode.utf8ValidateSlice(last_diff.text));
                std.debug.assert(std.unicode.utf8ValidateSlice(diff.text));
                if (@as(f64, @floatFromInt(overlap_length1)) >= @as(f64, @floatFromInt(std.unicode.utf8CountCodepoints(last_diff.text) catch unreachable)) / 2 or
                    @as(f64, @floatFromInt(overlap_length1)) >= @as(f64, @floatFromInt(std.unicode.utf8CountCodepoints(diff.text) catch unreachable)) / 2)
                {
                    // Overlap found. Insert an equality and trim the surrounding edits.
                    try diff_list.insert(allocator, pointer, try Diff.fromSlice(allocator, diff.text[0..overlap_length1], .equal));

                    _ = try utils.resize(u8, allocator, &diff_list.items[pointer - 1].text, last_diff.text.len - overlap_length1);

                    std.mem.copyForwards(u8, diff.text[0 .. diff.text.len - overlap_length1], diff.text[overlap_length1..]);
                    _ = try utils.resize(u8, allocator, &diff_list.items[pointer + 1].text, diff.text.len - overlap_length1);

                    pointer += 1;
                }
            } else {
                std.debug.assert(std.unicode.utf8ValidateSlice(last_diff.text));
                std.debug.assert(std.unicode.utf8ValidateSlice(diff.text));
                if (@as(f64, @floatFromInt(overlap_length2)) >= @as(f64, @floatFromInt(std.unicode.utf8CountCodepoints(last_diff.text) catch unreachable)) / 2 or
                    @as(f64, @floatFromInt(overlap_length2)) >= @as(f64, @floatFromInt(std.unicode.utf8CountCodepoints(diff.text) catch unreachable)) / 2)
                {
                    // Reverse overlap found. Insert an equality and swap and trim the surrounding edits.
                    try diff_list.insert(allocator, pointer, try Diff.fromSlice(allocator, last_diff.text[0..overlap_length2], .equal));
                    diff_list.items[pointer - 1].operation = .insert;
                    diff_list.items[pointer - 1].text = diff.text;
                    diff_list.items[pointer + 1].operation = .delete;
                    diff_list.items[pointer + 1].text = last_diff.text;

                    _ = try utils.resize(u8, allocator, &diff_list.items[pointer - 1].text, diff.text.len - overlap_length2);

                    std.mem.copyForwards(
                        u8,
                        diff_list.items[pointer + 1].text[0 .. last_diff.text.len - overlap_length2],
                        last_diff.text[overlap_length2..],
                    );
                    _ = try utils.resize(u8, allocator, &diff_list.items[pointer + 1].text, last_diff.text.len - overlap_length2);

                    pointer += 1;
                }
            }
            pointer += 1;
        }
        pointer += 1;
    }

    diffs.* = try diff_list.toOwnedSlice(allocator);
}

///Look for single edits surrounded on both sides by equalities
///which can be shifted sideways to align the edit to a word boundary.
///e.g: The c<ins>at c</ins>ame. -> The <ins>cat </ins>came.
pub fn cleanupSemanticLossless(allocator: Allocator, diffs: *[]Diff) !void {
    if (diffs.len == 0) return;

    var diff_list = std.ArrayList(Diff).fromOwnedSlice(diffs.*);
    defer diff_list.deinit(allocator);
    errdefer if (diff_list.toOwnedSlice(allocator)) |diff_o| {
        diffs.* = diff_o;
    } else |_| {};

    // Intentionally ignore the first and last element (don't need checking).
    var pointer: usize = 1;
    while (pointer < diff_list.items.len - 1) {
        if (diff_list.items[pointer - 1].operation == .equal and
            diff_list.items[pointer + 1].operation == .equal)
        {
            // This is a single edit surrounded by equalities.
            var equality1: std.ArrayList(u8) = .{};
            defer equality1.deinit(allocator);
            try equality1.appendSlice(allocator, diff_list.items[pointer - 1].text);

            var edit: std.ArrayList(u8) = .{};
            defer edit.deinit(allocator);
            try edit.appendSlice(allocator, diff_list.items[pointer].text);

            var equality2: std.ArrayList(u8) = .{};
            defer equality2.deinit(allocator);
            try equality2.appendSlice(allocator, diff_list.items[pointer + 1].text);

            // First, shift the edit as far left as possible.
            const common_offset = commonSuffix(equality1.items, edit.items);
            if (common_offset > 0) {
                equality1.items.len -= common_offset;

                try equality2.insertSlice(allocator, 0, edit.items[edit.items.len - common_offset ..]);

                std.mem.copyBackwards(u8, edit.items[common_offset..], edit.items[0 .. edit.items.len - common_offset]);
                std.mem.copyForwards(u8, edit.items[0..common_offset], equality2.items[0..common_offset]);
            }

            // Second, step character by character right, looking for the best fit.
            // these are used to chop up the lists
            var best_equality1_len = equality1.items.len;
            var edit_start: usize = 0;
            var equality2_start: usize = 0;
            var best_score = DiffPrivate.cleanupSemanticScore(equality1.items, edit.items) +
                DiffPrivate.cleanupSemanticScore(edit.items, equality2.items);

            while (edit.items.len - edit_start != 0 and
                equality2.items.len - equality2_start != 0)
            {
                const cp_len = std.unicode.utf8ByteSequenceLength(edit.items[edit_start]) catch break;
                if (equality2.items.len - equality2_start < cp_len or
                    !std.mem.eql(u8, edit.items[edit_start .. edit_start + cp_len], equality2.items[equality2_start .. equality2_start + cp_len]))
                {
                    break;
                }

                try equality1.appendSlice(allocator, edit.items[edit_start .. edit_start + cp_len]);

                try edit.appendSlice(allocator, equality2.items[equality2_start .. equality2_start + cp_len]);
                edit_start += cp_len;

                equality2_start += cp_len;

                const score = DiffPrivate.cleanupSemanticScore(equality1.items, edit.items[edit_start..]) +
                    DiffPrivate.cleanupSemanticScore(edit.items[edit_start..], equality2.items[equality2_start..]);
                // The >= encourages trailing rather than leading whitespace on edits.
                if (score >= best_score) {
                    best_score = score;
                    best_equality1_len = equality1.items.len;

                    std.mem.copyForwards(u8, edit.items[0 .. edit.items.len - edit_start], edit.items[edit_start..]);
                    edit.items.len -= edit_start;
                    edit_start = 0;

                    std.mem.copyForwards(u8, equality2.items[0 .. equality2.items.len - equality2_start], equality2.items[equality2_start..]);
                    equality2.items.len -= equality2_start;
                    equality2_start = 0;
                }
            }

            if (!std.mem.eql(u8, diff_list.items[pointer - 1].text, equality1.items[0..best_equality1_len])) {
                // We have an improvement, save it back to the diff.
                if (best_equality1_len != 0) {
                    allocator.free(diff_list.items[pointer - 1].text);
                    equality1.items.len = best_equality1_len;
                    diff_list.items[pointer - 1].text = try equality1.toOwnedSlice(allocator);
                } else {
                    var last_diff = diff_list.orderedRemove(pointer - 1);
                    last_diff.deinit(allocator);
                    pointer -= 1;
                }

                allocator.free(diff_list.items[pointer].text);
                edit.items.len -= edit_start;
                diff_list.items[pointer].text = try edit.toOwnedSlice(allocator);

                if (equality2.items.len - equality2_start != 0) {
                    allocator.free(diff_list.items[pointer + 1].text);
                    diff_list.items[pointer + 1].text = try equality2.toOwnedSlice(allocator);
                } else {
                    var next_diff = diff_list.orderedRemove(pointer + 1);
                    next_diff.deinit(allocator);
                    pointer -= 1;
                }
            }
        }
        pointer += 1;
    }

    diffs.* = try diff_list.toOwnedSlice(allocator);
}

///Reduce the number of edits by eliminating operationally trivial equalities.
pub fn cleanupEfficiency(allocator: Allocator, diff_edit_cost: u16, diffs: *[]Diff) Allocator.Error!void {
    if (diffs.len == 0) return;

    var diff_list = std.ArrayList(Diff).fromOwnedSlice(diffs.*);
    defer diff_list.deinit(allocator);
    errdefer if (diff_list.toOwnedSlice(allocator)) |diff_o| {
        diffs.* = diff_o;
    } else |_| {};

    var changes = false;

    var equalities = try std.ArrayList(usize).initCapacity(allocator, diff_list.items.len);
    defer equalities.deinit(allocator);

    var last_equality: ?[]const u8 = null;
    var pointer: usize = 0;
    // Is there an insertion operation before the last equality.
    var pre_insert = false;
    // Is there a deletion operation before the last equality.
    var pre_delete = false;
    // Is there an insertion operation after the last equality.
    var post_insert = false;
    // Is there a deletion operation after the last equality.
    var post_delete = false;

    while (pointer < diff_list.items.len) {
        const diff = diff_list.items[pointer];
        if (diff.operation == .equal) {
            // Equality found.
            if (diff.text.len < diff_edit_cost and (post_insert or post_delete)) {
                // Candidate found.
                equalities.appendAssumeCapacity(pointer);
                pre_insert = post_insert;
                pre_delete = post_delete;
                last_equality = diff.text;
            } else {
                // Not a candidate and can never become one.
                equalities.clearRetainingCapacity();
                last_equality = null;
            }
            post_insert = false;
            post_delete = false;

            pointer += 1;
            continue;
        }

        // An insertion or deletion.
        if (diff.operation == .delete) {
            post_delete = true;
        } else {
            post_insert = true;
        }

        // Five types to be split:
        // <ins>A</ins><del>B</del>XY<ins>C</ins><del>D</del>
        // <ins>A</ins>X<ins>C</ins><del>D</del>
        // <ins>A</ins><del>B</del>X<ins>C</ins>
        // <ins>A</del>X<ins>C</ins><del>D</del>
        // <ins>A</ins><del>B</del>X<del>C</del>
        const sum_pres = blk: {
            var int: u3 = 0;
            if (pre_insert) int += 1;
            if (pre_delete) int += 1;
            if (post_insert) int += 1;
            if (post_delete) int += 1;
            break :blk int;
        };
        if (last_equality != null and
            ((pre_insert and pre_delete and post_insert and post_delete) or
                ((last_equality.?.len < diff_edit_cost / 2) and sum_pres == 3)))
        {
            // Duplocate record.
            try diff_list.insert(allocator, equalities.getLast(), try Diff.fromSlice(allocator, last_equality.?, .delete));

            // Change second copy to insert.
            diff_list.items[equalities.getLast() + 1].operation = .insert;
            // Throw away equality that was just deleted.
            equalities.items.len -= 1;
            last_equality = null;

            if (pre_insert and pre_delete) {
                // No changes made which could affect previous entry, keep going.
                post_insert = true;
                post_delete = true;
                equalities.clearRetainingCapacity();
                pointer += 1;
            } else {
                if (equalities.items.len > 0) {
                    equalities.items.len -= 1;
                }
                if (equalities.items.len > 0) {
                    pointer = equalities.getLast() + 1;
                } else {
                    pointer = 0;
                }
                post_insert = false;
                post_delete = false;
            }
            changes = true;
            continue;
        }

        pointer += 1;
    }

    if (changes) {
        diffs.* = try diff_list.toOwnedSlice(allocator);
        try cleanupMerge(allocator, diffs);
        diff_list.capacity = diffs.len;
        diff_list.items = diffs.*;
    }

    diffs.* = try diff_list.toOwnedSlice(allocator);
}

///Reorder and merge like edit sections.  Merge equalities.
///Any edit section can move as long as it doesn't cross an equality.
pub fn cleanupMerge(allocator: Allocator, diffs: *[]Diff) !void {
    if (diffs.len == 0) return;
    var diff_list = std.ArrayList(Diff).fromOwnedSlice(diffs.*);
    defer diff_list.deinit(allocator);
    errdefer if (diff_list.toOwnedSlice(allocator)) |diff_o| {
        diffs.* = diff_o;
    } else |_| {};

    // Add a dummy entry at the end.
    try diff_list.append(allocator, try Diff.fromSlice(allocator, "", .equal));
    var pointer: usize = 0;
    var count_delete: usize = 0;
    var count_insert: usize = 0;
    var common_length: usize = 0;

    var text_insert: std.ArrayList(u8) = .{};
    defer text_insert.deinit(allocator);
    var text_delete: std.ArrayList(u8) = .{};
    defer text_delete.deinit(allocator);

    while (pointer < diff_list.items.len) {
        var diff = diff_list.items[pointer];
        switch (diff.operation) {
            .insert => {
                count_insert += 1;
                try text_insert.appendSlice(allocator, diff.text);
                pointer += 1;
            },
            .delete => {
                count_delete += 1;
                try text_delete.appendSlice(allocator, diff.text);
                pointer += 1;
            },
            .equal => {
                // Upon reaching an equality, check for prior redundancies.
                if (count_delete + count_insert > 1) {
                    if (count_delete != 0 and count_insert != 0) {
                        // Factor out any common prefixies.
                        common_length = commonPrefix(text_insert.items, text_delete.items);
                        if (common_length != 0) {
                            const x = pointer - count_delete - count_insert;
                            const common_text = text_insert.items[0..common_length];
                            if (x > 0 and diff_list.items[x - 1].operation == .equal) {
                                const old_len = try utils.resize(u8, allocator, &diff_list.items[x - 1].text, diff_list.items[x - 1].text.len + common_length);
                                // TODO: switch to memmove
                                std.mem.copyForwards(u8, diff_list.items[x - 1].text[old_len .. old_len + common_length], common_text);
                            } else {
                                try diff_list.insert(allocator, 0, try Diff.fromSlice(allocator, common_text, .equal));
                                pointer += 1;
                            }

                            std.mem.copyForwards(u8, text_insert.items[0 .. text_insert.items.len - common_length], text_insert.items[common_length..]);
                            text_insert.items.len -= common_length;
                            std.mem.copyForwards(u8, text_delete.items[0 .. text_delete.items.len - common_length], text_delete.items[common_length..]);
                            text_delete.items.len -= common_length;
                        }

                        // Factor out any common suffixies.
                        common_length = commonSuffix(text_insert.items, text_delete.items);
                        if (common_length != 0) {
                            const old_len = try utils.resize(u8, allocator, &diff.text, diff.text.len + common_length);
                            std.mem.copyBackwards(u8, diff.text[common_length..], diff.text[0..old_len]);
                            std.mem.copyForwards(u8, diff.text[0..common_length], text_insert.items[text_insert.items.len - common_length ..]);

                            text_insert.items.len -= common_length;
                            text_delete.items.len -= common_length;
                            diff_list.items[pointer] = diff;
                        }
                    }

                    // Delete the offending records and add the merged ones.
                    const del_count = count_delete + count_insert;
                    if (count_delete == 0) {
                        const delete_loc = pointer - count_insert;
                        for (diff_list.items[delete_loc .. delete_loc + del_count]) |*d| d.deinit(allocator);
                        try diff_list.replaceRange(allocator, delete_loc, del_count, &.{try Diff.fromSlice(allocator, text_insert.items, .insert)});
                    } else if (count_insert == 0) {
                        const delete_loc = pointer - count_delete;
                        for (diff_list.items[delete_loc .. delete_loc + del_count]) |*d| d.deinit(allocator);
                        try diff_list.replaceRange(allocator, delete_loc, del_count, &.{try Diff.fromSlice(allocator, text_delete.items, .delete)});
                    } else {
                        const delete_loc = pointer - count_delete - count_insert;
                        for (diff_list.items[delete_loc .. delete_loc + del_count]) |*d| d.deinit(allocator);
                        try diff_list.replaceRange(allocator, delete_loc, del_count, &.{
                            try Diff.fromSlice(allocator, text_delete.items, .delete),
                            try Diff.fromSlice(allocator, text_insert.items, .insert),
                        });
                    }

                    pointer = pointer - count_delete - count_insert + 1;
                    if (count_delete != 0) {
                        pointer += 1;
                    }
                    if (count_insert != 0) {
                        pointer += 1;
                    }
                } else if (pointer != 0 and diff_list.items[pointer - 1].operation == .equal) {
                    // Merge this equality with the previous one.
                    var last_diff = diff_list.items[pointer - 1];
                    const old_len = try utils.resize(u8, allocator, &last_diff.text, last_diff.text.len + diff.text.len);
                    std.mem.copyForwards(u8, last_diff.text[old_len..], diff.text);

                    diff_list.items[pointer - 1] = last_diff;

                    diff.deinit(allocator);
                    _ = diff_list.orderedRemove(pointer);
                } else {
                    pointer += 1;
                }
                count_insert = 0;
                count_delete = 0;
                text_insert.clearRetainingCapacity();
                text_delete.clearRetainingCapacity();
            },
        }
    }

    if (diff_list.getLast().text.len == 0) {
        // Remove the dummy entry at the end.
        diff_list.items[diff_list.items.len - 1].deinit(allocator);
        _ = diff_list.orderedRemove(diff_list.items.len - 1);
    }

    //Second pass: look for single edits surrounded on both sides by equalities
    //which can be shifted sideways to eliminate an equality.
    //e.g: A<ins>BA</ins>C -> <ins>AB</ins>AC
    var changes = false;
    pointer = 1;
    // Intentionally ignore the first and last element (don't need checking).
    while (diff_list.items.len > 2 and pointer < diff_list.items.len - 1) {
        var diff = diff_list.items[pointer];
        var last_diff = diff_list.items[pointer - 1];
        var next_diff = diff_list.items[pointer + 1];
        if (last_diff.operation == .equal and next_diff.operation == .equal) {
            // This is a single edit surrounded by equalities.
            if (std.mem.endsWith(u8, diff.text, last_diff.text)) {
                // Shift the edit over the previous equality.
                std.mem.copyBackwards(u8, diff.text[last_diff.text.len..diff.text.len], diff.text[0 .. diff.text.len - last_diff.text.len]);
                std.mem.copyForwards(u8, diff.text[0..last_diff.text.len], last_diff.text);

                const old_len = try utils.resize(u8, allocator, &next_diff.text, last_diff.text.len + next_diff.text.len);
                std.mem.copyBackwards(u8, next_diff.text[last_diff.text.len..], next_diff.text[0..old_len]);
                std.mem.copyForwards(u8, next_diff.text[0..last_diff.text.len], last_diff.text);

                diff_list.items[pointer + 1] = next_diff;

                last_diff.deinit(allocator);
                _ = diff_list.orderedRemove(pointer - 1);
                changes = true;
            } else if (std.mem.startsWith(u8, diff.text, next_diff.text)) {
                // Shift the edit over the next equality.
                // diffs[pointer-1].Text += next_diff.text
                const old_len = try utils.resize(u8, allocator, &last_diff.text, last_diff.text.len + next_diff.text.len);
                std.mem.copyForwards(u8, last_diff.text[old_len..], next_diff.text);

                std.mem.copyForwards(u8, diff.text[0 .. diff.text.len - next_diff.text.len], diff.text[next_diff.text.len..]);
                std.mem.copyForwards(u8, diff.text[diff.text.len - next_diff.text.len ..], next_diff.text);

                diff_list.items[pointer - 1] = last_diff;

                next_diff.deinit(allocator);
                _ = diff_list.orderedRemove(pointer + 1);
                changes = true;
            }
        }
        pointer += 1;
    }

    diffs.* = try diff_list.toOwnedSlice(allocator);

    // If shifts were made, the diff needs reordering and another shift sweep.
    if (changes) {
        try cleanupMerge(allocator, diffs);
    }
}

///loc is a location in text1, compute and return the equivalent location in text2.
///e.g. "The cat" vs "The big cat", 1->1, 5->8
pub fn xIndex(diffs: []const Diff, loc: usize) usize {
    var chars1: usize = 0;
    var chars2: usize = 0;
    var last_chars1: usize = 0;
    var last_chars2: usize = 0;
    var last_diff: ?Diff = undefined;
    for (diffs) |diff| {
        if (diff.operation != .insert) {
            // Equality or deletion.
            chars1 += diff.text.len;
        }
        if (diff.operation != .delete) {
            // Equality or insertion.
            chars2 += diff.text.len;
        }
        if (chars1 > loc) {
            // Overshot the location.
            last_diff = diff;
            break;
        }
        last_chars1 = chars1;
        last_chars2 = chars2;
    }

    if (last_diff != null and last_diff.?.operation == .delete) {
        // The location was deleted.
        return last_chars2;
    }
    // Add the remaining character length.
    return last_chars2 + (loc - last_chars1);
}

///Convert a Diff list into a pretty HTML report.
pub fn prettyHtml(allocator: Allocator, diffs: []const Diff) (Allocator.Error || std.Io.Writer.Error)!StrType {
    var text = std.Io.Writer.Allocating.init(allocator);
    defer text.deinit();
    try prettyHtmlWriter(&text.writer, diffs);
    if (options.nullTerminated)
        return text.toOwnedSliceSentinel(0)
    else
        return text.toOwnedSlice();
}
pub fn prettyHtmlWriter(writer: *std.Io.Writer, diffs: []const Diff) std.Io.Writer.Error!void {
    for (diffs) |diff|
        switch (diff.operation) {
            .equal => {
                try writer.writeAll("<span>");
                try writeHtmlSanitized(writer, diff.text);
                try writer.writeAll("</span>");
            },
            .delete => {
                try writer.writeAll("<del style=\"background:#ffe6e6;\">");
                try writeHtmlSanitized(writer, diff.text);
                try writer.writeAll("</del>");
            },
            .insert => {
                try writer.writeAll("<ins style=\"background:#e6ffe6;\">");
                try writeHtmlSanitized(writer, diff.text);
                try writer.writeAll("</ins>");
            },
        };
}
fn writeHtmlSanitized(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var start: usize = 0;
    for (text, 0..) |char, i| {
        const replacement: []const u8 = switch (char) {
            '\n' => "&para;<br>",
            '<' => "&lt;",
            '>' => "&gt;",
            '&' => "&amp;",
            else => continue,
        };
        try writer.print("{s}{s}", .{ text[start..i], replacement });
        start = i + 1;
    }
    try writer.writeAll(text[start..]);
}

///Converts a []Diff into a colored text report.
pub fn prettyText(allocator: Allocator, diffs: []const Diff) (Allocator.Error || std.Io.Writer.Error)!StrType {
    var text = std.Io.Writer.Allocating.init(allocator);
    defer text.deinit();
    try prettyTextWriter(&text.writer, diffs);
    if (options.nullTerminated)
        return text.toOwnedSliceSentinel(0)
    else
        return text.toOwnedSlice();
}
pub fn prettyTextWriter(writer: *std.Io.Writer, diffs: []const Diff) std.Io.Writer.Error!void {
    for (diffs) |diff|
        switch (diff.operation) {
            .equal => try writer.writeAll(diff.text),
            .insert => try writer.print("\x1b[32m{s}\x1b[0m", .{diff.text}),
            .delete => try writer.print("\x1b[31m{s}\x1b[0m", .{diff.text}),
        };
}

pub fn getText(allocator: Allocator, diffs: []const Diff, original: bool) Allocator.Error!StrType {
    const skipOp: Diff.Operation = if (original) .insert else .delete;
    var len: usize = 0;
    for (diffs) |diff| {
        if (diff.operation == skipOp) continue;
        len += diff.text.len;
    }
    const text = if (options.nullTerminated)
        try allocator.allocSentinel(u8, len, 0)
    else
        try allocator.alloc(u8, len);

    var writer = std.Io.Writer.fixed(text);

    for (diffs) |diff| {
        if (diff.operation == skipOp) continue;
        writer.writeAll(diff.text) catch unreachable;
    }
    std.debug.assert(writer.end == text.len);

    return text;
}

///Compute and return the source text (all equalities and deletions).
pub fn text1(allocator: Allocator, diffs: []const Diff) Allocator.Error!StrType {
    return getText(allocator, diffs, true);
}

///Compute and return the destination text (all equalities and insertions).
pub fn text2(allocator: Allocator, diffs: []const Diff) Allocator.Error!StrType {
    return getText(allocator, diffs, false);
}

///Compute the Levenshtein distance; the number of inserted, deleted or substituted characters.
pub fn levenshtein(diffs: []const Diff) usize {
    var levenshtein_d: usize = 0;
    var insertions: usize = 0;
    var deletions: usize = 0;

    for (diffs) |diff| {
        std.debug.assert(std.unicode.utf8ValidateSlice(diff.text));
        switch (diff.operation) {
            .insert => insertions += std.unicode.utf8CountCodepoints(diff.text) catch unreachable,
            .delete => deletions += std.unicode.utf8CountCodepoints(diff.text) catch unreachable,
            .equal => {
                // A deletion and an insertion is one substitution.
                levenshtein_d += @max(insertions, deletions);
                insertions = 0;
                deletions = 0;
            },
        }
    }
    levenshtein_d += @max(insertions, deletions);
    return levenshtein_d;
}

///Crush the diff into an encoded string which describes the operations
///required to transform text1 into text2.
///E.g. =3\t-2\t+ing  -> Keep 3 chars, delete 2 chars, insert 'ing'.
///Operations are tab-separated.  Inserted text is escaped using %xx notation.
pub fn toDelta(allocator: Allocator, diffs: []const Diff) (Allocator.Error || std.Io.Writer.Error)!StrType {
    var text = std.Io.Writer.Allocating.init(allocator);
    defer text.deinit();
    try toDeltaWriter(&text.writer, diffs);
    if (options.nullTerminated)
        return text.toOwnedSliceSentinel(0)
    else
        return text.toOwnedSlice();
}
pub fn toDeltaWriter(writer: *std.Io.Writer, diffs: []const Diff) std.Io.Writer.Error!void {
    for (diffs, 1..) |diff, i| {
        std.debug.assert(std.unicode.utf8ValidateSlice(diff.text));
        switch (diff.operation) {
            .equal => try writer.print("={d}", .{std.unicode.utf8CountCodepoints(diff.text) catch unreachable}),
            .delete => try writer.print("-{d}", .{std.unicode.utf8CountCodepoints(diff.text) catch unreachable}),
            .insert => {
                try writer.writeByte('+');
                try utils.encodeURI(writer, diff.text);
            },
        }
        if (diffs.len != i) try writer.writeByte('\t');
    }
}

///Given the original text1, and an encoded string which describes the
///operations required to transform text1 into text2, compute the full diff.
pub fn fromDelta(allocator: Allocator, text_a: []const u8, delta: []const u8) (Error || std.mem.Allocator.Error)![]Diff {
    var diffs: std.ArrayList(Diff) = .{};
    defer diffs.deinit(allocator);
    errdefer for (diffs.items) |diff| diff.deinit(allocator);

    var pointer: usize = 0;
    var tokens = std.mem.splitScalar(u8, delta, '\t');
    while (tokens.next()) |token| {
        if (token.len == 0) {
            // Blank tokens are ok (from a trailing \t).
            continue;
        }

        // Each token begins with a one character parameter which specifies the
        // operation of this token (delete, insert, equality).
        const param = token[1..];
        switch (token[0]) {
            '+' => {
                const param_encoded = try allocator.alloc(u8, param.len);
                defer allocator.free(param_encoded);
                @memcpy(param_encoded, param);
                const line = std.Uri.percentDecodeInPlace(param_encoded);
                if (!std.unicode.utf8ValidateSlice(line)) return Error.DeltaContainsInvalidUTF8;
                try diffs.append(allocator, try Diff.fromSlice(allocator, line, .insert));
            },
            '-', '=' => {
                const count = std.fmt.parseInt(isize, param, 10) catch return Error.DeltaBadNumber;
                if (count < 0) return Error.DeltaContainsNegetiveNumber;

                if (pointer > text_a.len) return Error.DeltaLongerThenSource;

                var len: usize = 0;
                for (0..@intCast(count)) |_| {
                    if (pointer + len >= text_a.len) return Error.DeltaLongerThenSource;
                    len += std.unicode.utf8ByteSequenceLength(text_a[pointer + len]) catch return Error.DeltaContainsInvalidUTF8;
                }
                if (pointer + len > text_a.len) return Error.DeltaLongerThenSource;

                const line = text_a[pointer .. pointer + len];
                pointer += len;
                if (token[0] == '=') {
                    try diffs.append(allocator, try Diff.fromSlice(allocator, line, .equal));
                } else {
                    try diffs.append(allocator, try Diff.fromSlice(allocator, line, .delete));
                }
            },
            else => return Error.DeltaContainsIlligalOperation,
        }
    }
    if (pointer > text_a.len) return Error.DeltaLongerThenSource;
    if (pointer < text_a.len) return Error.DeltaShorterThenSource;
    return diffs.toOwnedSlice(allocator);
}
