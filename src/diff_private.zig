const std = @import("std");
const utils = @import("utils.zig");
const diff_funcs = @import("diff.zig");

const Diff = @import("diff.zig").Diff;
const DiffOperation = @import("diff.zig").Operation;

const Allocator = std.mem.Allocator;

const isWasm = @import("builtin").target.os.tag == .freestanding and @import("builtin").target.cpu.arch.isWasm();
const Timer = if (!isWasm)
    std.time.Timer
else
    struct {
        start_time: u64,

        extern fn readTimeNs() callconv(.c) c_long;
        pub fn start() !Timer {
            return .{
                .start_time = @intCast(readTimeNs()),
            };
        }
        pub fn read(self: *Timer) u64 {
            const time: u64 = @intCast(readTimeNs());
            std.debug.assert(time > self.start_time);
            return time - self.start_time;
        }
    };

pub const LineArray = struct {
    const S = @This();
    items: *[][]const u8,
    array_list: *std.ArrayListUnmanaged([]const u8),
    allocator: Allocator,
    pub fn init(allocator: Allocator) !S {
        var array_list = try allocator.create(std.ArrayListUnmanaged([]const u8));
        array_list.* = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator, 0);
        return .{
            .items = &array_list.items,
            .array_list = array_list,
            .allocator = allocator,
        };
    }
    pub fn fromSlice(allocator: Allocator, slice: [][]const u8) !S {
        var s = try S.init(allocator);
        for (slice) |item| try s.append(item);
        return s;
    }
    pub fn deinit(self: *S) void {
        for (self.array_list.items) |item| self.allocator.free(item);
        self.array_list.deinit(self.allocator);
        self.allocator.destroy(self.array_list);
        self.* = undefined;
    }
    pub fn append(self: S, text: []const u8) Allocator.Error!void {
        const text_copy = try self.allocator.alloc(u8, text.len);
        @memcpy(text_copy, text);
        try self.array_list.append(self.allocator, text_copy);
    }
};

///Find the differences between two texts.  Simplifies the problem by
///stripping any common prefix or suffix off the texts before diffing.
pub fn mainStringStringBoolTimeout(allocator: Allocator, diff_timeout: f32, text1: []const u8, text2: []const u8, check_lines: bool, ns_time_limit: u64) ![]Diff {
    var timer = Timer.start() catch @panic("Timer not available");

    const t1_valid = std.unicode.utf8ValidateSlice(text1);
    const t2_valid = std.unicode.utf8ValidateSlice(text2);

    const t1 = if (t1_valid) text1 else try utils.decodeUtf8(allocator, text1);
    defer if (!t1_valid) allocator.free(t1);

    const t2 = if (t2_valid) text2 else try utils.decodeUtf8(allocator, text2);
    defer if (!t2_valid) allocator.free(t2);

    return mainStringStringBoolTimeoutTimer(allocator, diff_timeout, t1, t2, check_lines, ns_time_limit, &timer);
}
fn mainStringStringBoolTimeoutTimer(allocator: Allocator, diff_timeout: f32, text1: []const u8, text2: []const u8, check_lines: bool, ns_time_limit: u64, timer: *Timer) Allocator.Error![]Diff {
    var diffs: std.ArrayList(Diff) = .{};
    defer diffs.deinit(allocator);
    errdefer for (diffs.items) |*diff| diff.deinit(allocator);

    std.debug.assert(std.unicode.utf8ValidateSlice(text1));
    std.debug.assert(std.unicode.utf8ValidateSlice(text2));

    // Check for equality (speedup).
    if (std.mem.eql(u8, text1, text2)) {
        if (text1.len != 0) {
            try diffs.append(allocator, try Diff.fromSlice(allocator, text1, .equal));
        }
        return diffs.toOwnedSlice(allocator);
    }

    var text_chopped1: []const u8 = undefined;
    var text_chopped2: []const u8 = undefined;
    var common_prefix: []const u8 = undefined;
    var common_suffix: []const u8 = undefined;

    // Trim off common prefix (speedup).
    {
        const common_length = diff_funcs.commonPrefix(text1, text2);
        common_prefix = text1[0..common_length];
        text_chopped1 = text1[common_length..];
        text_chopped2 = text2[common_length..];
    }

    // Trim off common suffix (speedup).
    {
        const common_length = diff_funcs.commonSuffix(text_chopped1, text_chopped2);
        common_suffix = text_chopped1[text_chopped1.len - common_length ..];
        text_chopped1 = text_chopped1[0 .. text_chopped1.len - common_length];
        text_chopped2 = text_chopped2[0 .. text_chopped2.len - common_length];
    }

    // Compute the diff on the middle block.
    {
        const computed_diffs = computeTimer(allocator, diff_timeout, text_chopped1, text_chopped2, check_lines, ns_time_limit, timer) catch |e| switch (e) {
            error.InvalidUtf8 => unreachable,
            else => return @as(Allocator.Error, @errorCast(e)),
        };
        defer allocator.free(computed_diffs);
        errdefer for (computed_diffs) |*diff| diff.deinit(allocator);
        try diffs.appendSlice(allocator, computed_diffs);
    }

    // Restore the prefix and suffix.
    if (common_prefix.len != 0) {
        try diffs.insert(allocator, 0, try Diff.fromSlice(allocator, common_prefix, .equal));
    }
    if (common_suffix.len != 0) {
        try diffs.append(allocator, try Diff.fromSlice(allocator, common_suffix, .equal));
    }

    var res = try diffs.toOwnedSlice(allocator);
    try diff_funcs.cleanupMerge(allocator, &res);

    return res;
}

///Find the differences between two texts.  Assumes that the texts do not
///have any common prefix or suffix.
pub fn compute(allocator: Allocator, diff_timeout: f32, text1: []const u8, text2: []const u8, checklines: bool, ns_time_limit: u64) ![]Diff {
    var timer = Timer.start() catch @panic("Timer not available");
    return computeTimer(allocator, diff_timeout, text1, text2, checklines, ns_time_limit, &timer);
}
fn computeTimer(allocator: Allocator, diff_timeout: f32, text1: []const u8, text2: []const u8, checklines: bool, ns_time_limit: u64, timer: *Timer) (error{InvalidUtf8} || Allocator.Error)![]Diff {
    switch (@import("builtin").mode) {
        .Debug, .ReleaseSafe => if (!std.unicode.utf8ValidateSlice(text1) or !std.unicode.utf8ValidateSlice(text2)) return error.InvalidUtf8,
        else => {},
    }

    std.debug.assert(std.unicode.utf8ValidateSlice(text1));
    std.debug.assert(std.unicode.utf8ValidateSlice(text2));

    var diffs: std.ArrayList(Diff) = .{};
    defer diffs.deinit(allocator);
    errdefer for (diffs.items) |*diff| diff.deinit(allocator);

    if (text1.len == 0) {
        // Just add some text (speedup).
        try diffs.append(allocator, try Diff.fromSlice(allocator, text2, .insert));
        return diffs.toOwnedSlice(allocator);
    }

    if (text2.len == 0) {
        // Just delete some text (speedup).
        try diffs.append(allocator, try Diff.fromSlice(allocator, text1, .delete));
        return diffs.toOwnedSlice(allocator);
    }

    const text1_longer = text1.len > text2.len;
    const long_text = if (text1_longer) text1 else text2;
    const short_text = if (text1_longer) text2 else text1;
    if (std.mem.indexOf(u8, long_text, short_text)) |idx| {
        // Shorter text is inside the longer text (speedup).
        const op = if (text1_longer) DiffOperation.delete else DiffOperation.insert;
        try diffs.append(allocator, try Diff.fromSlice(allocator, long_text[0..idx], op));
        try diffs.append(allocator, try Diff.fromSlice(allocator, short_text, .equal));
        try diffs.append(allocator, try Diff.fromSlice(allocator, long_text[idx + short_text.len ..], op));
        return diffs.toOwnedSlice(allocator);
    }

    if (short_text.len == 1) {
        // Single character string.
        // After the previous speedup, the character can't be an equality.
        try diffs.append(allocator, try Diff.fromSlice(allocator, text1, .delete));
        try diffs.append(allocator, try Diff.fromSlice(allocator, text2, .insert));
        return diffs.toOwnedSlice(allocator);
    }

    // Check to see if the problem can be split in two.
    if (try halfMatch(allocator, diff_timeout, text1, text2)) |hm| {
        errdefer allocator.free(hm.common);
        // A half-match was found, sort out the return data.
        // Send both pairs off for separate processing.
        const diffs_a = try mainStringStringBoolTimeoutTimer(allocator, diff_timeout, hm.text1_prefix, hm.text2_prefix, checklines, ns_time_limit, timer);
        defer allocator.free(diffs_a);
        const diffs_b = try mainStringStringBoolTimeoutTimer(allocator, diff_timeout, hm.text1_suffix, hm.text2_suffix, checklines, ns_time_limit, timer);
        defer allocator.free(diffs_b);

        // Merge the results.
        try diffs.appendSlice(allocator, diffs_a);
        try diffs.append(allocator, Diff{ .text = hm.common, .operation = .equal });
        try diffs.appendSlice(allocator, diffs_b);

        return diffs.toOwnedSlice(allocator);
    }

    // Perform a real diff.
    if (checklines and text1.len > 100 and text2.len > 100) {
        return lineModeTimer(allocator, diff_timeout, text1, text2, ns_time_limit, timer);
    }
    return bisectTimer(allocator, diff_timeout, text1, text2, ns_time_limit, timer);
}

///Do a quick line-level diff on both strings, then rediff the parts for
///greater accuracy.
///This speedup can produce non-minimal diffs.
pub fn lineMode(allocator: Allocator, diff_timeout: f32, text1: []const u8, text2: []const u8, ns_time_limit: u64) ![]Diff {
    var timer = Timer.start() catch @panic("Timer not available");
    return lineModeTimer(allocator, diff_timeout, text1, text2, ns_time_limit, &timer);
}
fn lineModeTimer(allocator: Allocator, diff_timeout: f32, text1: []const u8, text2: []const u8, ns_time_limit: u64, timer: *Timer) ![]Diff {
    var diffs: []Diff = undefined;

    {
        // Scan the text on a line-by-line basis first.
        var t1 = try utils.decodeUtf8(allocator, text1);
        defer allocator.free(t1);

        var t2 = try utils.decodeUtf8(allocator, text2);
        defer allocator.free(t2);

        var linearray = try linesToChars(allocator, &t1, &t2);
        defer linearray.deinit();

        diffs = try mainStringStringBoolTimeoutTimer(allocator, diff_timeout, t1, t2, false, ns_time_limit, timer);
        errdefer {
            for (diffs) |*diff| diff.deinit(allocator);
            allocator.free(diffs);
        }

        // Convert the diff back to original text.
        try charsToLinesLineArray(allocator, &diffs, linearray);
        // Eliminate freak matches (e.g. blank lines)
        try diff_funcs.cleanupSemantic(allocator, &diffs);
    }

    // Rediff any replacement blocks. this time charecter-by-charecter.
    // Add a dummy entry at the the end.
    var diff_list = std.ArrayList(Diff).fromOwnedSlice(diffs);
    defer diff_list.deinit(allocator);
    errdefer for (diff_list.items) |*diff| diff.deinit(allocator);
    try diff_list.append(allocator, try Diff.fromSlice(allocator, "", .equal));

    var pointer: usize = 0;
    var count_delete: usize = 0;
    var count_insert: usize = 0;

    var text_insert: std.ArrayList(u8) = .{};
    defer text_insert.deinit(allocator);
    var text_delete: std.ArrayList(u8) = .{};
    defer text_delete.deinit(allocator);

    while (pointer < diff_list.items.len) {
        const diff = diff_list.items[pointer];
        switch (diff.operation) {
            .insert => {
                count_insert += 1;
                try text_insert.appendSlice(allocator, diff.text);
            },
            .delete => {
                count_delete += 1;
                try text_delete.appendSlice(allocator, diff.text);
            },
            .equal => {
                // Upon reaching an equality. check for prior redundancies.
                if (count_delete >= 1 and count_insert >= 1) {
                    // Delete the offending records and add the merged ones.
                    const del_idx = pointer - count_delete - count_insert;
                    const del_len = count_delete + count_insert;

                    for (diff_list.items[del_idx .. del_idx + del_len]) |*d| d.deinit(allocator);
                    try diff_list.replaceRange(allocator, del_idx, del_len, &.{});
                    pointer = del_idx;

                    const a = try mainStringStringBoolTimeoutTimer(allocator, diff_timeout, text_delete.items, text_insert.items, false, ns_time_limit, timer);
                    defer allocator.free(a);
                    errdefer for (a) |*d| d.deinit(allocator);

                    try diff_list.insertSlice(allocator, pointer, a);
                    pointer += a.len;
                }

                count_insert = 0;
                count_delete = 0;
                text_delete.clearRetainingCapacity();
                text_insert.clearRetainingCapacity();
            },
        }
        pointer += 1;
    }

    // remove dummy entry at the end
    std.debug.assert(diff_list.items.len > 0);
    diff_list.items.len -= 1;
    return diff_list.toOwnedSlice(allocator);
}

///Find the 'middle snake' of a diff, split the problem in two
///and return the recursively constructed diff.
///See Myers 1986 paper: An O(ND) Difference Algorithm and Its Variations.
pub fn bisect(allocator: Allocator, diff_timeout: f32, text1: []const u8, text2: []const u8, ns_time_limit: u64) ![]Diff {
    var timer = Timer.start() catch @panic("Timer not available");
    return bisectTimer(allocator, diff_timeout, text1, text2, ns_time_limit, &timer);
}
fn bisectTimer(allocator: Allocator, diff_timeout: f32, text1: []const u8, text2: []const u8, ns_time_limit: u64, timer: *Timer) (error{InvalidUtf8} || Allocator.Error)![]Diff {
    // TODO: redo this function without all the casting and isizes
    const t1_valid = std.unicode.utf8ValidateSlice(text1);
    const t2_valid = std.unicode.utf8ValidateSlice(text2);

    // NOTE: this makes it silently error and replace the invalid utf8 rather then noping out
    const t1 = if (t1_valid) text1 else try utils.decodeUtf8(allocator, text1);
    defer if (!t1_valid) allocator.free(t1);

    const t2 = if (t2_valid) text2 else try utils.decodeUtf8(allocator, text2);
    defer if (!t2_valid) allocator.free(t2);

    const text1_len = std.unicode.utf8CountCodepoints(t1) catch unreachable;
    const text2_len = std.unicode.utf8CountCodepoints(t2) catch unreachable;

    const max_d: isize = @intCast((text1_len + text2_len + 1) / 2);
    const v_offset = max_d;
    const v_length = 2 * max_d;

    var v1 = try allocator.alloc(isize, @intCast(v_length));
    defer allocator.free(v1);
    var v2 = try allocator.alloc(isize, @intCast(v_length));
    defer allocator.free(v2);
    for (v1, v2) |*v1e, *v2e| {
        v1e.* = -1;
        v2e.* = -1;
    }

    v1[@intCast(v_offset + 1)] = 0;
    v2[@intCast(v_offset + 1)] = 0;

    const delta = @as(isize, @intCast(text1_len)) - @as(isize, @intCast(text2_len));
    // if the total number of charecters is odd, then the front path will
    // collide with the reverse path.
    const front = @mod(delta, 2) != 0;
    // Offsets for start and end of k loop.
    // Prevents mapping of space beyond the grid.
    var k1_start: isize = 0;
    var k1_end: isize = 0;
    var k2_start: isize = 0;
    var k2_end: isize = 0;
    for (0..@intCast(max_d)) |ud| {
        const d: isize = @intCast(ud);
        // Bail out if deadline is reached.
        if (timer.read() > ns_time_limit) {
            break;
        }

        // Walk the front path one step.
        var k1 = k1_start - d;
        while (k1 <= d - k1_end) : (k1 += 2) {
            const k1_offset = v_offset + k1;
            var x1: isize = if (k1 == -d or (k1 != d and v1[@intCast(k1_offset - 1)] < v1[@intCast(k1_offset + 1)]))
                v1[@intCast(k1_offset + 1)]
            else
                v1[@intCast(k1_offset - 1)] + 1;
            var y1 = x1 - k1;
            while (@as(usize, @intCast(x1)) < text1_len and @as(usize, @intCast(y1)) < text2_len and
                t1[utils.utf8IdxOfX(t1, @intCast(x1)).?] == t2[utils.utf8IdxOfX(t2, @intCast(y1)).?]) // NOTE: it might be faster to store string as decoded codepoints rather then looping to location every time
            {
                x1 += 1;
                y1 += 1;
            }
            v1[@intCast(k1_offset)] = x1;
            if (x1 > text1_len) {
                // Ran off the right of the graph.
                k1_end += 2;
            } else if (y1 > text2_len) {
                // Ran off the bottom of the graph.
                k1_start += 2;
            } else if (front) {
                const k2_offset = v_offset + delta - k1;
                if (k2_offset >= 0 and k2_offset < v_length and v2[@intCast(k2_offset)] != -1) {
                    // Mirror x2 onto the top-left coordinate system.
                    const x2 = @as(isize, @intCast(text1_len)) - v2[@intCast(k2_offset)];
                    if (x1 >= x2) {
                        // Overlap detected.
                        return bisectSplitTimer(allocator, diff_timeout, t1, t2, @intCast(x1), @intCast(y1), ns_time_limit, timer) catch |e| switch (e) {
                            error.OutOfBounds => unreachable,
                            else => @as(error{ OutOfMemory, InvalidUtf8 }, @errorCast(e)),
                        };
                    }
                }
            }
        }

        // Walk the reverse path one step.
        var k2 = k2_start - d;
        while (k2 <= d - k2_end) : (k2 += 2) {
            const k2_offset = v_offset + k2;
            var x2 = if (k2 == -d or (k2 != d and v2[@intCast(k2_offset - 1)] < v2[@intCast(k2_offset + 1)]))
                v2[@intCast(k2_offset + 1)]
            else
                v2[@intCast(k2_offset - 1)] + 1;
            var y2 = x2 - k2;
            while (@as(usize, @intCast(x2)) < text1_len and @as(usize, @intCast(y2)) < text2_len and
                t1[utils.utf8IdxOfX(t1, @intCast(@as(isize, @intCast(text1_len)) - x2 - 1)).?] ==
                    t2[utils.utf8IdxOfX(t2, @intCast(@as(isize, @intCast(text2_len)) - y2 - 1)).?])
            {
                x2 += 1;
                y2 += 1;
            }
            v2[@intCast(k2_offset)] = x2;
            if (@as(usize, @intCast(x2)) > text1_len) {
                // Ran off the left of the graph.
                k2_end += 2;
            } else if (@as(usize, @intCast(y2)) > text2_len) {
                k2_start += 2;
            } else if (!front) {
                const k1_offset = v_offset + delta - k2;
                if (k1_offset >= 0 and k1_offset < v_length and v1[@intCast(k1_offset)] != -1) {
                    const x1 = v1[@intCast(k1_offset)];
                    const y1 = v_offset + x1 - k1_offset;
                    // Mirror x2 onto top-left coordinate system
                    x2 = @intCast(text1_len - @as(usize, @intCast(x2)));
                    if (x1 >= x2) {
                        // Overlap detected
                        return bisectSplitTimer(allocator, diff_timeout, t1, t2, @intCast(x1), @intCast(y1), ns_time_limit, timer) catch |e| switch (e) {
                            error.OutOfBounds => unreachable,
                            else => @as(error{ OutOfMemory, InvalidUtf8 }, @errorCast(e)),
                        };
                    }
                }
            }
        }
    }

    // Diff took too long and hit deadline or
    // number of diffs equals number of characters, no commonalitry at all.
    var diffs = try allocator.alloc(Diff, 2);
    errdefer allocator.free(diffs);
    diffs[0] = try Diff.fromSlice(allocator, t1, .delete);
    errdefer diffs[0].deinit(allocator);
    diffs[1] = try Diff.fromSlice(allocator, t2, .insert);
    errdefer diffs[1].deinit(allocator);
    return diffs;
}

///Given the location of the 'middle snake', split the diff in two parts
///and recurse.
pub fn bisectSplit(allocator: Allocator, diff_timeout: f32, text1: []const u8, text2: []const u8, x: usize, y: usize, ns_time_limit: u64) ![]Diff {
    var timer = Timer.start() catch @panic("Timer not available");
    return bisectSplitTimer(allocator, diff_timeout, text1, text2, x, y, ns_time_limit, &timer);
}
fn bisectSplitTimer(allocator: Allocator, diff_timeout: f32, text1: []const u8, text2: []const u8, x: usize, y: usize, ns_time_limit: u64, timer: *Timer) (error{ InvalidUtf8, OutOfBounds } || Allocator.Error)![]Diff {
    const xn = utils.utf8IdxOfX(text1, x);
    const yn = utils.utf8IdxOfX(text2, y);
    if (xn == null or yn == null) return error.OutOfBounds;

    const text1a = text1[0..xn.?];
    const text2a = text2[0..yn.?];
    const text1b = text1[xn.?..];
    const text2b = text2[yn.?..];

    var diffs1 = try mainStringStringBoolTimeoutTimer(allocator, diff_timeout, text1a, text2a, false, ns_time_limit, timer);
    errdefer allocator.free(diffs1);
    errdefer for (diffs1) |*diff| diff.deinit(allocator);

    const diffs2 = try mainStringStringBoolTimeoutTimer(allocator, diff_timeout, text1b, text2b, false, ns_time_limit, timer);
    defer allocator.free(diffs2);
    errdefer for (diffs2) |*diff| diff.deinit(allocator);

    const old_len = try utils.resize(Diff, allocator, &diffs1, diffs1.len + diffs2.len);
    @memcpy(diffs1.ptr[old_len..], diffs2);

    return diffs1;
}

///Split two texts into a list of strings.  Reduce the texts to a string of
///hashes where each Unicode character represents one line.
pub fn linesToChars(allocator: Allocator, text1: *[]u8, text2: *[]u8) Allocator.Error!LineArray {
    var line_array = try LineArray.init(allocator);
    errdefer line_array.deinit();
    var line_hash = std.StringHashMap(usize).init(allocator);
    defer line_hash.deinit();
    // e.g. linearray[4] == "Hello\n"
    // e.g. linehash.get("Hello\n") == 4

    // "\x00" is a valid character, but various debuggers don't like it.
    // So we'll insert a junk entry to avoid generating a null character.
    try line_array.append("");

    try linesToCharsMunge(allocator, text1, &line_array, &line_hash);
    try linesToCharsMunge(allocator, text2, &line_array, &line_hash);

    return line_array;
}

///Split a text into a list of strings.  Reduce the texts to a string of
///hashes where each Unicode character represents one line.
pub fn linesToCharsMunge(allocator: Allocator, text_ref: *[]u8, line_array: *LineArray, line_hash: *std.StringHashMap(usize)) Allocator.Error!void {
    var text = text_ref.*;
    // changing the implementation to modify the string
    var lines = std.mem.splitScalar(u8, text, '\n');

    var codes_len: usize = 0;

    while (lines.next()) |hl| {
        if (hl.len == 0 and lines.index == null) continue; // skip empty end
        const idx = lines.index orelse (text.len - hl.len);
        const length = if (lines.index == null) hl.len else hl.len + 1;
        const line = hl.ptr[0..length]; // include newline
        var line_value = line_hash.get(line);
        if (line_value == null) {
            try line_array.append(line);
            line_value = line_array.items.len - 1;
            try line_hash.put(line_array.items.*[line_value.?], line_value.?);
        }

        const len = std.unicode.utf8CodepointSequenceLength(@intCast(line_value.?)) catch unreachable;
        // TODO: resize less often by doing capacity
        if (codes_len + len > idx + line.len) {
            const new_len = text.len + (len - ((idx + line.len) - codes_len));
            const old_len = try utils.resize(u8, allocator, &text, new_len);
            if (codes_len + len > old_len) std.mem.copyBackwards(u8, text[codes_len + len .. new_len], text[codes_len + 1 .. old_len]);
        }
        _ = std.unicode.utf8Encode(@intCast(line_value.?), text[codes_len .. codes_len + len]) catch @panic("couldent write codepoint for some reason");
        codes_len += len;
    }

    if (codes_len != text.len) {
        _ = try utils.resize(u8, allocator, &text, codes_len);
    }
    text_ref.* = text;
}
pub fn charsToLinesLineArray(allocator: Allocator, diffs: *[]Diff, line_array: LineArray) Allocator.Error!void {
    return charsToLines(allocator, diffs, line_array.items.*);
}

///Rehydrate the text in a diff from a string of line hashes to real lines of text.
pub fn charsToLines(allocator: Allocator, diffs: *[]Diff, line_array: [][]const u8) Allocator.Error!void {
    var text: std.ArrayList(u21) = .{};
    defer text.deinit(allocator);
    for (diffs.*) |*diff| {
        text.clearRetainingCapacity();
        try text.ensureTotalCapacity(allocator, diff.text.len); // will most likely be shorter but this is the max needed to hold it
        var len: usize = 0;
        var i: usize = 0;
        while (i < diff.text.len) : (i += 1) {
            const length = std.unicode.utf8ByteSequenceLength(diff.text[i]) catch continue;
            const codepoint = std.unicode.utf8Decode(diff.text[i .. i + @as(usize, @intCast(length))]) catch @panic("problem decoding utf8");
            i += @intCast(length - 1);
            text.appendAssumeCapacity(codepoint);
            len += line_array[codepoint].len;
        }

        _ = try utils.resize(u8, allocator, &diff.text, len);

        i = 0;
        for (text.items) |codepoint| {
            const line = line_array[codepoint];
            @memcpy(diff.text[i .. i + line.len], line);
            i += line.len;
        }
        std.debug.assert(i == diff.text.len);
    }
}

///Determine if the suffix of one string is the prefix of another.
pub fn commonOverlap(text1: []const u8, text2: []const u8) usize {
    if (text1.len == 0 or text2.len == 0) return 0;
    var t1 = text1;
    var t2 = text2;

    // Truncate the longer string.
    if (text1.len > text2.len) {
        t1 = text1[text1.len - text2.len ..];
    } else {
        t2 = text2[0..text1.len];
    }

    const text_length = @min(text1.len, text2.len);
    // Quick check for worse case.
    if (std.mem.eql(u8, t1, t2)) {
        return text_length;
    }

    // Start by looking for a single character match
    // and increase length until no match is found.
    // Performance analysis: http://neil.fraser.name/news/2010/11/04/
    var best: usize = 0;
    var length: usize = 1;
    while (true) {
        const pattern = t1[text_length - length ..];
        const found = std.mem.indexOf(u8, t2, pattern) orelse break;
        length += found;
        if (found == 0 or std.mem.eql(u8, t1[text_length - length ..], t2[0..text_length])) {
            best = length;
            length += 1;
        }
    }

    // should be utf8 compatible since the end of a utf8 cant match the start
    std.debug.assert(std.unicode.utf8ValidateSlice(text2[0..best]));

    return best;
}

///Do the two texts share a substring which is at least half the length of the longer text?
///This speedup can produce non-minimal diffs.
pub fn halfMatch(allocator: Allocator, diff_timeout: f32, text1: []const u8, text2: []const u8) Allocator.Error!?struct {
    text1_prefix: []const u8,
    text1_suffix: []const u8,
    text2_prefix: []const u8,
    text2_suffix: []const u8,
    common: []u8, // needs to be freed
} {
    if (diff_timeout <= 0) {
        // Don't risk returning a non-optimal diff if we have unlimited time.
        return null;
    }

    const text1_longer = text1.len > text2.len;
    const longtext = if (text1_longer) text1 else text2;
    const shorttext = if (text1_longer) text2 else text1;
    if (longtext.len < 4 or shorttext.len * 2 < longtext.len) {
        return null; // Pointless.
    }

    // First check if the second quarter is the seed for a half-match.
    var hm1 = try halfMatchI(allocator, longtext, shorttext, (longtext.len + 3) / 4);
    errdefer if (hm1) |hm| allocator.free(hm.common);
    // Check again based on the third quarter.
    var hm2 = try halfMatchI(allocator, longtext, shorttext, (longtext.len + 1) / 2);
    errdefer if (hm2) |hm| allocator.free(hm.common);

    if (hm1 == null and hm2 == null) return null;
    if (hm1 != null and hm2 != null) {
        // Both matched.  Select the longest.
        if (hm1.?.common.len > hm2.?.common.len) {
            allocator.free(hm2.?.common);
        } else {
            allocator.free(hm1.?.common);
            hm1 = hm2;
        }

        // leave only one
        hm2 = null;
    }

    std.debug.assert((hm1 != null and hm2 == null) or (hm1 == null and hm2 != null));
    if (if (hm1 != null) hm1 else hm2) |hm| {
        return .{
            .common = hm.common,
            .text1_prefix = if (text1_longer) hm.longtext_prefix else hm.shorttext_prefix,
            .text1_suffix = if (text1_longer) hm.longtext_suffix else hm.shorttext_suffix,
            .text2_prefix = if (text1_longer) hm.shorttext_prefix else hm.longtext_prefix,
            .text2_suffix = if (text1_longer) hm.shorttext_suffix else hm.longtext_suffix,
        };
    }
    unreachable;
}

///Does a substring of shorttext exist within longtext such that the
///substring is at least half the length of longtext?
pub fn halfMatchI(allocator: Allocator, longtext: []const u8, shorttext: []const u8, i: usize) Allocator.Error!?struct {
    longtext_prefix: []const u8,
    longtext_suffix: []const u8,
    shorttext_prefix: []const u8,
    shorttext_suffix: []const u8,
    common: []u8, // needs to be freed
} {
    // Start with a 1/4 length substring at position i as a seed.
    const seed = longtext[i .. i + longtext.len / 4];

    var best_common_len: usize = 0;
    var best_common_a: []const u8 = undefined;
    var best_common_b: []const u8 = undefined;
    var best_longtext_a: []const u8 = undefined;
    var best_longtext_b: []const u8 = undefined;
    var best_shorttext_a: []const u8 = undefined;
    var best_shorttext_b: []const u8 = undefined;

    var j_p: ?usize = null;
    while (std.mem.indexOfPos(u8, shorttext, if (j_p) |j| j + 1 else 0, seed)) |j| {
        j_p = j;
        const prefix_length = diff_funcs.commonPrefix(longtext[i..], shorttext[j..]);
        const suffix_length = diff_funcs.commonSuffix(longtext[0..i], shorttext[0..j]);
        if (best_common_len < suffix_length + prefix_length) {
            best_common_a = shorttext[j - suffix_length .. j];
            best_common_b = shorttext[j .. j + prefix_length];
            best_common_len = best_common_a.len + best_common_b.len;
            best_longtext_a = longtext[0 .. i - suffix_length];
            best_longtext_b = longtext[i + prefix_length ..];
            best_shorttext_a = shorttext[0 .. j - suffix_length];
            best_shorttext_b = shorttext[j + prefix_length ..];
        }
    }

    if (best_common_len * 2 < longtext.len) return null;

    var best_common = try allocator.alloc(u8, best_common_len);
    @memcpy(best_common[0..best_common_a.len], best_common_a);
    @memcpy(best_common[best_common_a.len..], best_common_b);

    return .{
        .longtext_prefix = best_longtext_a,
        .longtext_suffix = best_longtext_b,
        .shorttext_prefix = best_shorttext_a,
        .shorttext_suffix = best_shorttext_b,
        .common = best_common,
    };
}

///Given two strings, compute a score representing whether the internal
///boundary falls on logical boundaries.
///Scores range from 6 (best) to 0 (worst).
pub fn cleanupSemanticScore(one: []const u8, two: []const u8) usize {
    if (one.len == 0 or two.len == 0) {
        // Edges are the best.
        return 6;
    }

    const char1 = one[one.len - 1];
    const char2 = two[0];
    const non_alpha_numeric1 = switch (char1) {
        '0'...'9', 'a'...'z', 'A'...'Z' => false,
        else => true,
    };
    const non_alpha_numeric2 = switch (char2) {
        '0'...'9', 'a'...'z', 'A'...'Z' => false,
        else => true,
    };

    const whitespace1 = non_alpha_numeric1 and utils.isWhitespace(char1);
    const whitespace2 = non_alpha_numeric2 and utils.isWhitespace(char2);

    const line_break1 = whitespace1 and switch (char1) {
        '\r', '\n' => true,
        else => false,
    };
    const line_break2 = whitespace2 and switch (char2) {
        '\r', '\n' => true,
        else => false,
    };

    const blank_line1 = line_break1 and utils.blankLineEnd(one);
    const blank_line2 = line_break2 and utils.blankLineStart(two);

    if (blank_line1 or blank_line2) {
        // Five points for blank lines.
        return 5;
    } else if (line_break1 or line_break2) {
        // Four points for line breaks.
        return 4;
    } else if (non_alpha_numeric1 and !whitespace1 and whitespace2) {
        // Three points for end of sentences.
        return 3;
    } else if (whitespace1 or whitespace2) {
        // Two points for whitespace.
        return 2;
    } else if (non_alpha_numeric1 or non_alpha_numeric2) {
        // One point for non-alphanumeric.
        return 1;
    }
    return 0;
}
