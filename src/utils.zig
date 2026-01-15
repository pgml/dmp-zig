const std = @import("std");

///Encodes a string with URI-style % escaping.
pub fn encodeURI(writer: *std.Io.Writer, string: []const u8) std.Io.Writer.Error!void {
    try std.Uri.Component.percentEncode(writer, string, encodeURIValid);
}
fn encodeURIValid(chr: u8) bool {
    return switch (chr) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '=', ':', ';', '\'', ',', '.', '/', '~', '!', '@', '#', '$', '&', '*', '(', ')', '_', '+', ' ', '?' => true,
        else => false,
    };
}

pub fn utf8IdxOfX(text: []const u8, x: usize) ?usize {
    std.debug.assert(std.unicode.utf8ValidateSlice(text));
    var itr = std.unicode.Utf8View.initUnchecked(text).iterator();
    for (0..x) |_| {
        _ = itr.nextCodepointSlice() orelse return null;
    }
    return itr.i;
}

///taking a potentially invalid utf8 string return new valid string
pub fn decodeUtf8(allocator: std.mem.Allocator, text: []const u8) error{ OutOfMemory, InvalidUtf8 }![]u8 {
    var writer = try std.Io.Writer.Allocating.initCapacity(allocator, text.len);
    defer writer.deinit();
    std.unicode.fmtUtf8(text).format(&writer.writer) catch return error.InvalidUtf8;
    return writer.toOwnedSlice();
}

pub fn initUtf8BackwardsIterator(text: []const u8) Utf8BackwardsIterator {
    return .{
        .bytes = text,
        .i = text.len,
    };
}

pub const Utf8BackwardsIterator = struct {
    bytes: []const u8,
    i: usize,

    pub fn nextCodepointSlice(it: *Utf8BackwardsIterator) ?[]const u8 {
        if (it.i == 0) {
            return null;
        }

        while (it.i > 0 and it.bytes[it.i - 1] & 0xC0 == 0x80) : (it.i -= 1) {
            if (it.i == 0) break;
        }
        it.i -= 1;

        const cp_len = std.unicode.utf8ByteSequenceLength(it.bytes[it.i]) catch unreachable;
        return it.bytes[it.i .. it.i + cp_len];
    }

    pub fn nextCodepoint(it: *Utf8BackwardsIterator) ?u21 {
        const slice = it.nextCodepointSlice() orelse return null;
        return std.unicode.utf8Decode(slice) catch unreachable;
    }

    /// Look ahead at the next n codepoints without advancing the iterator.
    /// If fewer than n codepoints are available, then return the remainder of the string.
    pub fn peek(it: *Utf8BackwardsIterator, n: usize) []const u8 {
        const original_i = it.i;
        defer it.i = original_i;

        var start_ix = original_i;
        var found: usize = 0;
        while (found < n) : (found += 1) {
            const next_codepoint = it.nextCodepointSlice() orelse return it.bytes[0..original_i];
            start_ix -= next_codepoint.len;
        }

        return it.bytes[start_ix..original_i];
    }
};

pub fn getIdxOrNull(comptime T: type, arrayList: std.ArrayList(T), idx: usize) ?T {
    if (idx >= arrayList.items.len) return null;
    return arrayList.items[idx];
}

///resizes a slice, returns the old size
pub fn resize(comptime T: type, allocator: std.mem.Allocator, slice: *[]T, new_len: usize) std.mem.Allocator.Error!usize {
    const len_start = slice.len;
    if (len_start == new_len) return len_start;
    if (allocator.resize(slice.*, new_len)) {
        slice.*.len = new_len;
        return len_start;
    }

    //failed to resize
    const new_slice = try allocator.alloc(T, new_len);
    const minLen = @min(new_len, len_start);
    @memcpy(new_slice[0..minLen], slice.*[0..minLen]);
    if (len_start < new_len) @memset(new_slice[len_start..], undefined);
    allocator.free(slice.*);
    slice.* = new_slice;
    return len_start;
}

///Emulates the regex
///`^@@ -(\d+),?(\d*) \+(\d+),?(\d*) @@$`
pub fn matchPatchHeader(text: []const u8) ?struct { usize, ?usize, usize, ?usize } {
    if (!std.mem.startsWith(u8, text, "@@ -") or
        !std.mem.endsWith(u8, text, " @@"))
        return null;

    // strip '@@ -'
    var pointer: usize = 4;

    const digits: []const u8 = "0123456789";

    const digit1_end_index = std.mem.indexOfNonePos(u8, text, pointer, digits) orelse return null;
    const digit1 = std.fmt.parseInt(usize, text[pointer..digit1_end_index], 10) catch return null;
    pointer = digit1_end_index;

    var digit2: ?usize = null;
    switch (text[pointer]) {
        ',' => {
            pointer += 1;
            const digit2_end_index = std.mem.indexOfNonePos(u8, text, pointer, digits) orelse return null;
            digit2 = std.fmt.parseInt(usize, text[pointer..digit2_end_index], 10) catch return null;
            pointer = digit2_end_index;
        },
        ' ' => {},
        else => return null,
    }

    // check ` +`
    if (!std.mem.eql(u8, text[pointer .. pointer + 2], " +")) return null;
    pointer += 2;

    const digit3_end_index = std.mem.indexOfNonePos(u8, text, pointer, digits) orelse return null;
    const digit3 = std.fmt.parseInt(usize, text[pointer..digit3_end_index], 10) catch return null;
    pointer = digit3_end_index;

    var digit4: ?usize = null;
    switch (text[pointer]) {
        ',' => {
            pointer += 1;
            const digit4_end_index = std.mem.indexOfNonePos(u8, text, pointer, digits) orelse return null;
            digit4 = std.fmt.parseInt(usize, text[pointer..digit4_end_index], 10) catch return null;
            pointer = digit4_end_index;
        },
        ' ' => {},
        else => return null,
    }

    // make sure that we are at the end only the ` @@` should be left
    if (pointer + 3 != text.len) return null;

    return .{ digit1, digit2, digit3, digit4 };
}

///Emulates the regex
///`\n\r?\n$`
pub fn blankLineEnd(text: []const u8) bool {
    if (text.len < 2) return false;

    //not \n$
    if (text[text.len - 1] != '\n') return false;
    //\n\n$
    if (text[text.len - 2] == '\n') return true;

    //\n\r\n$
    if (text.len >= 3 and text[text.len - 2] == '\r' and text[text.len - 3] == '\n') return true;
    return false;
}

///Emulates the regex
///`^\r?\n\r?\n`
pub fn blankLineStart(text: []const u8) bool {
    if (text.len < 2) return false;

    // fast paths
    //^\n\n
    if (text[0] == '\n' and text[1] == '\n') return true;
    //^\r\n\r\n
    if (text.len >= 4 and text[0] == '\r' and text[1] == '\n' and text[2] == '\r' and text[3] == '\n') return true;

    if (text.len < 3) return false;
    //^\n\r\n
    if (text[0] == '\n' and text[1] == '\r' and text[2] == '\n') return true;
    //^\r\n\n
    if (text[0] == '\r' and text[1] == '\n' and text[2] == '\n') return true;

    return false;
}

///returns true for all chars that the regex `\s` will match
pub fn isWhitespace(char: u8) bool {
    return switch (char) {
        ' ',
        '\t',
        '\r',
        '\n',
        0x0B, // \v vertical tab
        0x0C, // \f form feed
        => true,
        else => false,
    };
}

const testing = std.testing;

test "uri encode decode" {
    const TestCases = struct {
        text: []const u8,
        expect: []const u8,
    };
    var writer = std.Io.Writer.Allocating.init(testing.allocator);
    defer writer.deinit();

    for ([_]TestCases{ .{
        .text = "[^A-Za-z0-9%-=;',./~!@#$%&*%(%)_%+ %?]",
        .expect = "%5B%5EA-Za-z0-9%25-=;',./~!@#$%25&*%25(%25)_%25+ %25?%5D",
    }, .{
        .text = "ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789 - _ . ! ~ * ' ( ) ; / ? : @ & = + $ , # ",
        .expect = "ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789 - _ . ! ~ * ' ( ) ; / ? : @ & = + $ , # ",
    } }) |test_case| {
        writer.clearRetainingCapacity();
        try encodeURI(&writer.writer, test_case.text);
        var writen = writer.written();
        try testing.expectEqualStrings(test_case.expect, writen);

        writen = std.Uri.percentDecodeInPlace(writen);
        try testing.expectEqualStrings(test_case.text, writen);
    }
}

test "patch regex header" {
    var result = matchPatchHeader("Some string");
    try testing.expect(result == null);

    result = matchPatchHeader("@@ -32,0 +53 @@");
    try testing.expect(result != null);
    try testing.expect(result.?[0] == 32);
    try testing.expect(result.?[1] == 0);
    try testing.expect(result.?[2] == 53);
    try testing.expect(result.?[3] == null);

    result = matchPatchHeader("@@ -15 +20,42 @@");
    try testing.expect(result != null);
    try testing.expect(result.?[0] == 15);
    try testing.expect(result.?[1] == null);
    try testing.expect(result.?[2] == 20);
    try testing.expect(result.?[3] == 42);

    result = matchPatchHeader("@@ -700,420 +5000,69 @@");
    try testing.expect(result != null);
    try testing.expect(result.?[0] == 700);
    try testing.expect(result.?[1] == 420);
    try testing.expect(result.?[2] == 5000);
    try testing.expect(result.?[3] == 69);

    result = matchPatchHeader("@@ -1,0 +3,-4 @@");
    try testing.expect(result == null);
}

test "blank line start regex" {
    try testing.expect(blankLineStart("\n\n"));
    try testing.expect(blankLineStart("\r\n\n"));
    try testing.expect(blankLineStart("\n\r\n"));
    try testing.expect(blankLineStart("\r\n\r\n"));

    try testing.expect(!blankLineStart("r\n\r\n"));
    try testing.expect(!blankLineStart("\rn\r\n"));
    try testing.expect(!blankLineStart("\r\nr\n"));
    try testing.expect(!blankLineStart("\r\n\rn"));

    try testing.expect(!blankLineStart("r\n\n"));
    try testing.expect(!blankLineStart("\rn\n"));
    try testing.expect(!blankLineStart("\r\nn"));

    try testing.expect(!blankLineStart("n\r\n"));
    try testing.expect(!blankLineStart("\nr\n"));
    try testing.expect(!blankLineStart("\n\rn"));

    try testing.expect(!blankLineStart("n\n"));
    try testing.expect(!blankLineStart("\nn"));

    try testing.expect(!blankLineStart("something random"));
    try testing.expect(blankLineStart("\n\nsomething random"));
    try testing.expect(blankLineStart("\r\n\r\nsomething random"));
}

test "blank line end regex" {
    try testing.expect(blankLineEnd("\n\n"));
    try testing.expect(blankLineEnd("\n\r\n"));

    try testing.expect(!blankLineEnd("n\r\n"));
    try testing.expect(!blankLineEnd("\nr\n"));
    try testing.expect(!blankLineEnd("\n\rn"));

    try testing.expect(!blankLineEnd("n\n"));
    try testing.expect(!blankLineEnd("\nn"));

    try testing.expect(!blankLineEnd("something random"));
    try testing.expect(blankLineEnd("something random\n\n"));
    try testing.expect(blankLineEnd("something random\r\n\r\n"));
}

test "unicode count loc" {
    try testing.expectEqual(2, utf8IdxOfX("abcd", 2));
    try testing.expectEqual(0, utf8IdxOfX("abcd", 0));
    // try testing.expectEqual(error.InvalidUtf8, utf8IdxOfX("\xe0\xe5", 0));
    try testing.expectEqual(null, utf8IdxOfX("abcd", 10));
    try testing.expectEqual(4, utf8IdxOfX("abcd", 4));
    try testing.expectEqual(null, utf8IdxOfX("abcd", 5));

    const uni_str = "a✓bcd";
    const idx = utf8IdxOfX(uni_str, 2);
    try testing.expectEqual(4, idx);
    try testing.expectEqualStrings("bcd", uni_str[idx.?..]);
}

test "backwards iterator" {
    const str = "Hello, 世界";
    var itr = initUtf8BackwardsIterator(str);
    try testing.expectEqualStrings("o, 世界", itr.peek(5));
    try testing.expectEqualStrings("界", itr.nextCodepointSlice().?);
    try testing.expectEqual(19990, itr.nextCodepoint().?);
    _ = itr.nextCodepointSlice();
    _ = itr.nextCodepointSlice();
    try testing.expectEqualStrings("Hello", itr.peek(10));
    _ = itr.nextCodepointSlice();
    _ = itr.nextCodepointSlice();
    _ = itr.nextCodepointSlice();
    try testing.expectEqual('e', itr.nextCodepoint().?);
    try testing.expectEqualStrings("H", itr.nextCodepointSlice().?);
    try testing.expectEqual(null, itr.nextCodepointSlice());
    try testing.expectEqualStrings("", itr.peek(1));
}

test "resize" {
    var mem = try testing.allocator.alloc(u8, 5);
    defer testing.allocator.free(mem);

    try testing.expectEqual(5, mem.len);
    for (0..mem.len) |i| {
        mem[i] = @intCast(i + 1);
    }
    try testing.expectEqual(2, mem[1]);

    const old_len = try resize(u8, testing.allocator, &mem, mem.len + 3);
    @memset(mem[old_len..], 9);

    try testing.expectEqualDeep(&[_]u8{ 1, 2, 3, 4, 5, 9, 9, 9 }, mem);

    _ = try resize(u8, testing.allocator, &mem, 3);
    try testing.expectEqual(3, mem.len);
    try testing.expectEqual(3, mem[mem.len - 1]);

    _ = try resize(u8, testing.allocator, &mem, mem.len);
    try testing.expectEqual(3, mem.len);
    try testing.expectEqual(1, mem[0]);
}
