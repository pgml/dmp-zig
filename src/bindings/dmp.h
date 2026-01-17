#ifndef DMP_H
#define DMP_H

struct DiffMatchPatch {
    float diff_timeout = 1.0;
    ushort diff_edit_cost = 4;
    float match_threshold = 0.5;
    uint match_distance = 1000;
    float patch_delete_threshold = 0.5;
    ushort patch_margin = 4;
};

enum DiffOperation {
    diff_delete = -1,
    diff_equal = 0,
    diff_insert = 1,
};

struct Diff {
    DiffOperation operation;
    const char* text;
};

struct Patch {
    int start1;
    int start2;
    int length1;
    int length2;
    int diffs_len;
    Diff* diffs;
};

enum {
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
    function_diff_xindex,
    function_diff_pretty_html,
    function_diff_pretty_text,
    function_diff_text1,
    function_diff_text2,
    function_diff_levenshtein,
    function_diff_to_delta,
    function_diff_from_delta,
} ErrSource;

struct ErrorInfo {
    ErrSource source;
    const char* message;    
};

// void onError(ErrorInfo info);

void getLastError(ErrorInfo* info);

void freePatchList(PatchList* list, int patches_len);
void freeDiffList(DiffList* list, int diffs_len);
void freePatch(Patch* patch);
void freeDiff(Diff* diff);
void freeString(const char* str);

void getDefaultDMP(DiffMatchPatch* dmp);

int diffDiffMain(DiffMatchPatch* dmp, const char* text1, const char* text2, bool check_lines, Diff** out_diffs);
int diffCommonPrefix(const char* text1, const char* text2);
int diffCommonSuffix(const char* text1, const char* text2);
int diffCleanupSemantic(Diff** diffs,int diffs_len);
int diffCleanupSemanticLossless(Diff** diffs,int diffs_len);
int diffCleanupEfficiency(Diff** diffs,int diffs_len);
int diffCleanupMerge(Diff** diffs,int diffs_len);
int diffXIndex(Diff** diffs,int diffs_len, int loc);
const char* diffPrettyHtml(Diff** diffs,int diffs_len);
const char* diffPrettyText(Diff** diffs,int diffs_len);
const char* diffText1(Diff** diffs,int diffs_len);
const char* diffText2(Diff** diffs,int diffs_len);
int diffLevenshtein(Diff** diffs,int diffs_len);
const char* diffToDelta(Diff** diffs,int diffs_len);
int diffFromDelta(const char* text, const char* delta, Diff** out_diffs);

int matchMain(DiffMatchPatch* dmp, const char* text1, const char* pattern, int loc);

/**
 * Compute a list of patches to turn text1 into text2.
 * Use diffs if provided, otherwise compute it ourselves.
 * There are four ways to call this function, depending on what data is
 * available to the caller:
 * Method 1:
 * a = text1, b = text2
 * Method 2:
 * a = diffs, b = diffs_len
 * Method 3 (optimal):
 * a = text1, b = diffs, c = diffs_len
 * Method 4 (deprecated, use method 3):
 * a = text1, b = text2, c = diffs, d = diffs_len
 * returns pointer and len in out_patches_len
 */
int patchMake(DiffMatchPatch* dmp, Patch** out_patches, int mode, ...);
int patchMakeStringString(DiffMatchPatch* dmp, const char* text1, const char* text2, Patch** out_patches);
int patchMakeDiffs(DiffMatchPatch* dmp, Diff* diffs, int diffs_len, Patch** out_patches);
int patchMakeStringDiffs(DiffMatchPatch* dmp, const char* text1, Diff* diffs, int diffs_len, Patch** out_patches);
int patchMakeStringStringDiffs(DiffMatchPatch* dmp, const char* text1, const char* text2, Diff* diffs, int diffs_len, Patch** out_patches);

int patchDeepCopy(Patch* patches, int patches_len, Patch** out_patches);
const char* patchApply(DiffMatchPatch* dmp, Patch* patches, int patches_len, const char* text, bool** out_applied);
const char* patchAddPadding(DiffMatchPatch* dmp, Patch* patches, int patches_len, Patch** out_patches, int* out_patches_len);
const char* patchSplitMax(DiffMatchPatch* dmp, Patch* patches, int patches_len, Patch** out_patches, int* out_patches_len);
const char* patchToText(Patch* patches, int patches_len);
int patchFromText(const char* text, Patch** out_patches);
const char* patchObjToString(Patch p);

#endif // DMP_H