const std = @import("std");
const utils = @import("utils.zig");
const StrType = @import("dmp_options").StrType;

pub const diff = @import("diff.zig");
pub const match = @import("match.zig");
pub const patch = @import("patch.zig");

test {
    std.testing.refAllDeclsRecursive(@This());
}

pub const DiffMatchPatch = DiffMatchPatchCustom(u32);

pub const MatchError = match.MatchError;
pub const PatchError = patch.Error;
pub const DiffError = diff.Error;

pub const Diff = diff.Diff;
pub const deinitDiffList = diff.deinitDiffList;
pub const diff_max_duration = diff.diff_max_duration;

pub const PatchList = patch.PatchList;
// pub const PatchDiffsArrayList = patch.PatchDiffsArrayList;
pub const Patch = patch.Patch;

pub const default_diff_timeout: f32 = 1.0;
pub const default_diff_edit_cost: u16 = 4;
pub const default_match_threshold: f32 = 0.5;
pub const default_match_distance: u32 = 1000;
pub const default_patch_delete_threshold: f32 = 0.5;
pub const default_patch_margin: u16 = 4;

///DiffMatchPatch struct
///the container that determins the number of bits in an int
fn DiffMatchPatchCustom(MatchMaxContainer: type) type {
    return struct {
        ///Number of seconds to map a diff before giving up (0 for infinity).
        diff_timeout: f32 = default_diff_timeout,
        ///Cost of an empty edit operation in terms of edit characters.
        diff_edit_cost: u16 = default_diff_edit_cost,
        ///At what point is no match declared (0.0 = perfection, 1.0 = very loose).
        match_threshold: f32 = default_match_threshold,
        ///How far to search for a match (0 = exact location, 1000+ = broad match).
        ///A match this many characters away from the expected location will add
        ///1.0 to the score (0.0 is a perfect match).
        match_distance: u32 = default_match_distance,
        ///When deleting a large block of text (over ~64 characters), how close
        ///do the contents have to be to match the expected contents. (0.0 =
        ///perfection, 1.0 = very loose).  Note that Match_Threshold controls
        ///how closely the end points of a delete need to match.
        patch_delete_threshold: f32 = default_patch_delete_threshold,
        ///Chunk size for context length.
        patch_margin: u16 = default_patch_margin,

        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        // diff ------------------

        ///Find the differences between two texts.
        ///Run a faster, slightly less optimal diff.
        ///This method allows the 'checklines' of `diffMainStringStringBool` to be optional.
        ///Most of the time checklines is wanted, so default to true.
        pub inline fn diffMainStringString(self: Self, text1: []const u8, text2: []const u8) (error{InvalidUtf8} || std.mem.Allocator.Error)![]Diff {
            return diff.mainStringString(self.allocator, self.diff_timeout, text1, text2);
        }
        ///Find the differences between two texts.
        pub inline fn diffMainStringStringBool(self: Self, text1: []const u8, text2: []const u8, check_lines: bool) (error{InvalidUtf8} || std.mem.Allocator.Error)![]Diff {
            return diff.mainStringStringBool(self.allocator, self.diff_timeout, text1, text2, check_lines);
        }
        ///Determine the common prefix of two strings.
        pub inline fn diffCommonPrefix(self: Self, text1: []const u8, text2: []const u8) usize {
            _ = self;
            return diff.commonPrefix(text1, text2);
        }
        ///Determine the common suffix of two strings.
        pub inline fn diffCommonSuffix(self: Self, text1: []const u8, text2: []const u8) usize {
            _ = self;
            return diff.commonSuffix(text1, text2);
        }
        ///Reduce the number of edits by eliminating semantically trivial equalities.
        pub inline fn diffCleanupSemantic(self: Self, diffs: *[]Diff) std.mem.Allocator.Error!void {
            return diff.cleanupSemantic(self.allocator, diffs);
        }
        ///Look for single edits surrounded on both sides by equalities
        ///which can be shifted sideways to align the edit to a word boundary.
        ///e.g: The c<ins>at c</ins>ame. -> The <ins>cat </ins>came.
        pub inline fn diffCleanupSemanticLossless(self: Self, diffs: *[]Diff) std.mem.Allocator.Error!void {
            return diff.cleanupSemanticLossless(self.allocator, diffs);
        }
        ///Reduce the number of edits by eliminating operationally trivial equalities.
        pub inline fn diffCleanupEfficiency(self: Self, diffs: *[]Diff) std.mem.Allocator.Error!void {
            return diff.cleanupEfficiency(self.allocator, self.diff_edit_cost, diffs);
        }
        ///Reorder and merge like edit sections.  Merge equalities.
        ///Any edit section can move as long as it doesn't cross an equality.
        pub inline fn diffCleanupMerge(self: Self, diffs: *[]Diff) std.mem.Allocator.Error!void {
            return diff.cleanupMerge(self.allocator, diffs);
        }
        ///loc is a location in text1, compute and return the equivalent location in text2.
        ///e.g. "The cat" vs "The big cat", 1->1, 5->8
        pub inline fn diffXIndex(self: Self, diffs: []const Diff, loc: usize) usize {
            _ = self;
            return diff.xIndex(diffs, loc);
        }
        ///Convert a Diff list into a pretty HTML report.
        pub inline fn diffPrettyHtml(self: Self, diffs: []const Diff) (std.mem.Allocator.Error || std.Io.Writer.Error)!StrType {
            return diff.prettyHtml(self.allocator, diffs);
        }
        pub inline fn diffPrettyHtmlWriter(self: Self, writer: *std.Io.Writer, diffs: []const Diff) std.Io.Writer.Error!void {
            _ = self;
            return diff.prettyHtmlWriter(writer, diffs);
        }
        ///Converts a []Diff into a colored text report.
        pub inline fn diffPrettyText(self: Self, diffs: []const Diff) (std.mem.Allocator.Error || std.Io.Writer.Error)!StrType {
            return diff.prettyText(self.allocator, diffs);
        }
        pub inline fn diffPrettyTextWriter(self: Self, writer: *std.Io.Writer, diffs: []const Diff) std.Io.Writer.Error!void {
            _ = self;
            return diff.prettyTextWriter(writer, diffs);
        }
        ///Compute and return the source text (all equalities and deletions).
        pub inline fn diffText1(self: Self, diffs: []const Diff) std.mem.Allocator.Error!StrType {
            return diff.text1(self.allocator, diffs);
        }
        ///Compute and return the destination text (all equalities and insertions).
        pub inline fn diffText2(self: Self, diffs: []const Diff) std.mem.Allocator.Error!StrType {
            return diff.text2(self.allocator, diffs);
        }
        ///Compute the Levenshtein distance; the number of inserted, deleted or substituted characters.
        pub fn diffLevenshtein(self: Self, diffs: []const Diff) usize {
            _ = self;
            return diff.levenshtein(diffs);
        }
        ///Crush the diff into an encoded string which describes the operations
        ///required to transform text1 into text2.
        ///E.g. =3\t-2\t+ing  -> Keep 3 chars, delete 2 chars, insert 'ing'.
        ///Operations are tab-separated.  Inserted text is escaped using %xx notation.
        pub inline fn diffToDelta(self: Self, diffs: []const Diff) (std.mem.Allocator.Error || std.Io.Writer.Error)!StrType {
            return diff.toDelta(self.allocator, diffs);
        }
        pub inline fn diffToDeltaWriter(self: Self, writer: *std.Io.Writer, diffs: []const Diff) std.Io.Writer.Error!void {
            _ = self;
            return diff.toDeltaWriter(writer, diffs);
        }
        ///Given the original text1, and an encoded string which describes the
        ///operations required to transform text1 into text2, compute the full diff.
        pub fn diffFromDelta(self: Self, text1: []const u8, delta: []const u8) (DiffError || std.mem.Allocator.Error)![]Diff {
            return diff.fromDelta(self.allocator, text1, delta);
        }

        // match -----------------

        ///Locate the best instance of 'pattern' in 'text' near 'loc'.
        ///Returns null if no match found.
        pub inline fn matchMain(self: Self, text: []const u8, pattern: []const u8, loc: usize) (MatchError || std.mem.Allocator.Error)!?usize {
            return match.main(MatchMaxContainer, self.allocator, self.match_distance, self.match_threshold, text, pattern, loc);
        }
        ///Locate the best instance of 'pattern' in 'text' near 'loc' using the
        ///Bitap algorithm.  Returns null if no match found.
        pub inline fn matchBitap(self: Self, text: []const u8, pattern: []const u8, loc: usize) (MatchError || std.mem.Allocator.Error)!?usize {
            return match.bitap(MatchMaxContainer, self.allocator, self.match_distance, self.match_threshold, text, pattern, loc);
        }

        // patch -----------------

        ///Increase the context until it is unique,
        ///but don't let the pattern expand beyond match_max_bits.
        pub inline fn patchAddContext(self: Self, p: *Patch, text: []const u8) std.mem.Allocator.Error!void {
            return patch.addContext(MatchMaxContainer, self.allocator, self.patch_margin, p, text);
        }
        // patch make parts
        ///Compute a list of patches to turn text1 into text2.
        ///A set of diffs will be computed.
        pub inline fn patchMakeStringString(self: Self, text1: []const u8, text2: []const u8) (std.mem.Allocator.Error || error{InvalidUtf8})!PatchList {
            return patch.makeStringString(MatchMaxContainer, self.allocator, self.patch_margin, self.diff_edit_cost, self.diff_timeout, text1, text2);
        }
        ///Compute a list of patches to turn text1 into text2.
        ///text1 will be derived from the provided diffs.
        pub inline fn patchMakeDiffs(self: Self, diffs: []const Diff) std.mem.Allocator.Error!PatchList {
            return patch.makeDiffs(MatchMaxContainer, self.allocator, self.patch_margin, diffs);
        }
        ///Compute a list of patches to turn text1 into text2.
        ///text2 is ignored, diffs are the delta between text1 and text2.
        ///Depricated, use patchStringDiffs
        pub inline fn patchMakeStringStringDiffs(self: Self, text1: []const u8, text2: []const u8, diffs: []const Diff) std.mem.Allocator.Error!PatchList {
            return patch.makeStringStringDiffs(MatchMaxContainer, self.allocator, self.patch_margin, text1, text2, diffs);
        }
        ///Compute a list of patches to turn text1 into text2.
        ///text2 is not provided, diffs are the delta between text1 and text2.
        pub inline fn patchMakeStringDiffs(self: Self, text1: []const u8, diffs: []const Diff) std.mem.Allocator.Error!PatchList {
            return patch.makeStringDiffs(MatchMaxContainer, self.allocator, self.patch_margin, text1, diffs);
        }
        ///Given an array of patches, return another array that is identical.
        pub inline fn patchDeepCopy(self: Self, patches: PatchList) std.mem.Allocator.Error!PatchList {
            return patch.deepCopy(self.allocator, patches);
        }
        ///Merge a set of patches onto the text.  Return a patched text, as well
        ///as an array of true/false values indicating which patches were applied.
        pub inline fn patchApply(self: Self, patches: PatchList, text: []const u8) !struct { []const u8, []const bool } {
            return patch.apply(MatchMaxContainer, self.allocator, self.diff_timeout, self.match_distance, self.match_threshold, self.patch_margin, self.patch_delete_threshold, patches, text);
        }
        ///Add some padding on text start and end so that edges can match something.
        ///Intended to be called only from within `patchApply`.
        pub inline fn patchAddPadding(self: Self, patches: *PatchList) std.mem.Allocator.Error!StrType {
            return patch.addPadding(self.allocator, self.patch_margin, patches);
        }
        ///Look through the patches and break up any which are longer than the
        ///maximum limit of the match algorithm.
        ///Intended to be called only from within `patchApply`.
        pub inline fn patchSplitMax(self: Self, patches: *PatchList) std.mem.Allocator.Error!void {
            return patch.splitMax(MatchMaxContainer, self.allocator, self.patch_margin, patches);
        }
        ///Take a list of patches and return a textual representation.
        pub inline fn patchToText(self: Self, patches: PatchList) (std.mem.Allocator.Error || std.Io.Writer.Error)!StrType {
            return patch.toText(self.allocator, patches);
        }
        ///Parse a textual representation of patches and return a List of Patch objects.
        pub inline fn patchFromText(self: Self, textline: []const u8) (PatchError || std.mem.Allocator.Error)!PatchList {
            return patch.fromText(self.allocator, textline);
        }
    };
}
