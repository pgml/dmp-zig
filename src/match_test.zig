const DMP = @import("diffmatchpatch.zig").DiffMatchPatch;
const std = @import("std");
const testing = std.testing;
const options = @import("options");

const StrType = if (options.nullTerminated) [:0]const u8 else []const u8;

const MatchPrivate = @import("match_private.zig");

test "matchAlphabet" {
    const Container = u32;
    var expect: [255]?Container = undefined;
    var result: [255]?Container = undefined;

    //unique
    @memset(&expect, null);
    expect['a'] = 4;
    expect['b'] = 2;
    expect['c'] = 1;
    result = MatchPrivate.match_alphabet(Container, "abc");
    for (result, expect) |result_el, expect_el| try testing.expectEqual(expect_el, result_el);

    //duplicates
    @memset(&expect, null);
    expect['a'] = 37;
    expect['b'] = 18;
    expect['c'] = 8;
    result = MatchPrivate.match_alphabet(Container, "abcaba");
    for (result, expect) |result_el, expect_el| try testing.expectEqual(expect_el, result_el);
}

test "matchBitap" {
    var dmp = DMP.init(testing.allocator);
    dmp.match_distance = 100;
    dmp.match_threshold = 0.5;

    const TestCase = struct {
        text: StrType,
        pattern: StrType,
        location: usize,
        expect: ?usize,
    };

    for ([_]TestCase{
        .{ .text = "abcdefghijk", .pattern = "fgh", .location = 5, .expect = 5 },
        .{ .text = "abcdefghijk", .pattern = "fgh", .location = 0, .expect = 5 },
        .{ .text = "abcdefghijk", .pattern = "efxhi", .location = 0, .expect = 4 },
        .{ .text = "abcdefghijk", .pattern = "cdefxyhijk", .location = 5, .expect = 2 },
        .{ .text = "abcdefghijk", .pattern = "bxy", .location = 1, .expect = null },
        .{ .text = "123456789xx0", .pattern = "3456789x0", .location = 2, .expect = 2 },
        .{ .text = "abcdef", .pattern = "xxabc", .location = 4, .expect = 0 },
        .{ .text = "abcdef", .pattern = "defyy", .location = 4, .expect = 3 },
        .{ .text = "abcdef", .pattern = "xabcdefy", .location = 0, .expect = 0 },
    }) |test_case| {
        try testing.expectEqual(test_case.expect, try dmp.matchBitap(test_case.text, test_case.pattern, test_case.location));
    }

    dmp.match_threshold = 0.4;

    for ([_]TestCase{
        .{ .text = "abcdefghijk", .pattern = "efxyhi", .location = 1, .expect = 4 },
    }) |test_case| {
        try testing.expectEqual(test_case.expect, try dmp.matchBitap(test_case.text, test_case.pattern, test_case.location));
    }

    dmp.match_threshold = 0.3;

    for ([_]TestCase{
        .{ .text = "abcdefghijk", .pattern = "efxyhi", .location = 1, .expect = null },
    }) |test_case| {
        try testing.expectEqual(test_case.expect, try dmp.matchBitap(test_case.text, test_case.pattern, test_case.location));
    }

    dmp.match_threshold = 0.0;

    for ([_]TestCase{
        .{ .text = "abcdefghijk", .pattern = "bcdef", .location = 1, .expect = 1 },
    }) |test_case| {
        try testing.expectEqual(test_case.expect, try dmp.matchBitap(test_case.text, test_case.pattern, test_case.location));
    }

    dmp.match_threshold = 0.5;

    for ([_]TestCase{
        .{ .text = "abcdexyzabcde", .pattern = "abccde", .location = 3, .expect = 0 },
        .{ .text = "abcdexyzabcde", .pattern = "abccde", .location = 5, .expect = 8 },
    }) |test_case| {
        try testing.expectEqual(test_case.expect, try dmp.matchBitap(test_case.text, test_case.pattern, test_case.location));
    }

    dmp.match_distance = 10;

    for ([_]TestCase{
        .{ .text = "abcdefghijklmnopqrstuvwxyz", .pattern = "abcdefg", .location = 24, .expect = null },
        .{ .text = "abcdefghijklmnopqrstuvwxyz", .pattern = "abcdxxefg", .location = 1, .expect = 0 },
    }) |test_case| {
        try testing.expectEqual(test_case.expect, try dmp.matchBitap(test_case.text, test_case.pattern, test_case.location));
    }

    dmp.match_distance = 1000;

    for ([_]TestCase{
        .{ .text = "abcdefghijklmnopqrstuvwxyz", .pattern = "abcdefg", .location = 24, .expect = 0 },
    }) |test_case| {
        try testing.expectEqual(test_case.expect, try dmp.matchBitap(test_case.text, test_case.pattern, test_case.location));
    }
}

test "match main" {
    var dmp = DMP.init(testing.allocator);

    const TestCase = struct {
        text1: StrType,
        text2: StrType,
        location: usize,
        expect: ?usize,
    };

    for ([_]TestCase{
        .{ .text1 = "abcdef", .text2 = "abcdef", .location = 1000, .expect = 0 },
        .{ .text1 = "", .text2 = "abcdef", .location = 1, .expect = null },
        .{ .text1 = "abcdef", .text2 = "", .location = 3, .expect = 3 },
        .{ .text1 = "abcdef", .text2 = "de", .location = 3, .expect = 3 },
        .{ .text1 = "abcdef", .text2 = "defy", .location = 4, .expect = 3 },
        .{ .text1 = "abcdef", .text2 = "abcdefy", .location = 0, .expect = 0 },
    }) |test_case| {
        try testing.expectEqual(test_case.expect, try dmp.matchMain(test_case.text1, test_case.text2, test_case.location));
    }

    dmp.match_threshold = 0.7;

    for ([_]TestCase{
        .{ .text1 = "I am the very model of a modern major general.", .text2 = " that berry ", .location = 5, .expect = 4 },
    }) |test_case| {
        try testing.expectEqual(test_case.expect, try dmp.matchBitap(test_case.text1, test_case.text2, test_case.location));
    }
}
