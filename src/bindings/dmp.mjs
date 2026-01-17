
class DiffMatchPatch {
	onError = (errInfo) => console.error("wasm error", errInfo);

	DiffMatchPatchSettings = undefined;

	_exports = undefined;
	_memory = undefined;
	_alloced_memory_internal = [];

	constructor(wasmPromise) {
		this.readyPromise = WebAssembly.instantiateStreaming(
			wasmPromise,
			{
				env: {
					readTimeNs: () => window.performance.now() * 1000,
					onError: (errInfo) => {
						if (this.onError) this.onError(ErrorInfoStruct.deserialize(this._memory, errInfo));
					},
				},
			}
		).then((result) => {
			this._exports = result.instance.exports;
			this._memory = result.instance.exports.memory;
			this.DiffMatchPatchSettings = this._get_default_dmp();
			return this;
		});
	}

	_isReady() {
		if (!this._exports || !this._memory) {
			throw new Error("WASM not loaded. Did you forget to await .readyPromise?");
		}
	}

	_alloc(len) {
		this._isReady();
		if (this._exports.alloc == undefined) throw new Error("Wasm does not export alloc");
		const ptr = this._exports.alloc(len);
		this._alloced_memory_internal.push({ addr: ptr, len: len });
		return ptr;
	}

	_free(ptr) {
		this._isReady();
		if (this._exports.free == undefined) throw new Error("Wasm does not export free");
		const mem_addr = this._alloced_memory_internal.findIndex((x) => x.addr === ptr);
		if (mem_addr === -1) return;
		const mem = this._alloced_memory_internal.splice(mem_addr, 1)[0];
		this._exports.free(mem.addr, mem.len);
	}

	get_last_error() {
		this._isReady();
		const errInfoPtr = this._alloc(ErrorInfoStruct.size);
		this._exports.getLastError(errInfoPtr);
		const errInfo = ErrorInfoStruct.deserialize(this._memory, errInfoPtr);
		this._free(errInfoPtr);
		return errInfo;
	}

	_get_default_dmp() {
		this._isReady();
		const dmpPtr = this._alloc(DiffMatchPatchStruct.size);
		this._exports.getDefaultDMP(dmpPtr);
		const dmp = DiffMatchPatchStruct.deserialize(this._memory, dmpPtr);
		this._free(dmpPtr);
		return dmp;
	}

	// ========== DIFF FUNCTIONS ==========

	diff_main(text1, text2, check_lines = true) {
		this._isReady();
		const dmpPtr = writeStruct(this._memory, this._alloc.bind(this), DiffMatchPatchStruct, this.DiffMatchPatchSettings);
		const text1Ptr = writeString(this._memory, this._alloc.bind(this), text1);
		const text2Ptr = writeString(this._memory, this._alloc.bind(this), text2);
		const out_diffsPtr = this._alloc(4);

		const ret = this._exports.diffDiffMain(dmpPtr, text1Ptr, text2Ptr, check_lines, out_diffsPtr);

		this._free(dmpPtr);
		this._free(text1Ptr);
		this._free(text2Ptr);

		if (ret == -1) {
			this._free(out_diffsPtr);
			const error = this.get_last_error();
			throw new Error(error.message);
		}

		const diffsPtr = readNumber(this._memory, out_diffsPtr, 'u32');
		this._free(out_diffsPtr);

		const diffs = this._deserializeDiffList(diffsPtr, ret);
		this._exports.freeDiffList(diffsPtr, ret);
		return diffs;
	}

	diff_common_prefix(text1, text2) {
		this._isReady();
		const text1Ptr = writeString(this._memory, this._alloc.bind(this), text1);
		const text2Ptr = writeString(this._memory, this._alloc.bind(this), text2);
		const ret = this._exports.diffCommonPrefix(text1Ptr, text2Ptr);
		this._free(text1Ptr);
		this._free(text2Ptr);
		return ret;
	}

	diff_common_suffix(text1, text2) {
		this._isReady();
		const text1Ptr = writeString(this._memory, this._alloc.bind(this), text1);
		const text2Ptr = writeString(this._memory, this._alloc.bind(this), text2);
		const ret = this._exports.diffCommonSuffix(text1Ptr, text2Ptr);
		this._free(text1Ptr);
		this._free(text2Ptr);
		return ret;
	}

	diff_cleanup_semantic(diffs) {
		return this._diffCleanupHelper("diffCleanupSemantic", diffs);
	}

	diff_cleanup_semantic_lossless(diffs) {
		return this._diffCleanupHelper("diffCleanupSemanticLossless", diffs);
	}

	diff_cleanup_efficiency(diffs) {
		this._isReady();
		const dmpPtr = writeStruct(this._memory, this._alloc.bind(this), DiffMatchPatchStruct, this.DiffMatchPatchSettings);
		const diffsPtr = this._serializeDiffList(diffs);
		const out_diffsPtr = writeNumber(this._memory, this._alloc.bind(this), diffsPtr, 'u32');

		const ret = this._exports.diffCleanupEfficiency(dmpPtr, out_diffsPtr, diffs.length);
		this._free(dmpPtr);

		if (ret == -1) {
			this._free(out_diffsPtr);
			const error = this.get_last_error();
			throw new Error(error.message);
		}

		const newDiffsPtr = readNumber(this._memory, out_diffsPtr, 'u32');
		this._free(out_diffsPtr);

		const result = this._deserializeDiffList(newDiffsPtr, ret);
		this._exports.freeDiffList(newDiffsPtr, ret);
		return result;
	}

	diff_cleanup_merge(diffs) {
		return this._diffCleanupHelper("diffCleanupMerge", diffs);
	}

	diff_xindex(diffs, loc) {
		this._isReady();
		const diffsPtr = this._serializeDiffList(diffs);
		const ret = this._exports.diffXIndex(diffsPtr, diffs.length, loc);
		this._exports.freeDiffList(diffsPtr, diffs.length);

		if (ret == -1) {
			const error = this.get_last_error();
			throw new Error(error.message);
		}
		return ret;
	}

	diff_pretty_html(diffs) {
		return this._diffToStringHelper("diffPrettyHtml", diffs);
	}

	diff_pretty_text(diffs) {
		return this._diffToStringHelper("diffPrettyText", diffs);
	}

	diff_text1(diffs) {
		return this._diffToStringHelper("diffText1", diffs);
	}

	diff_text2(diffs) {
		return this._diffToStringHelper("diffText2", diffs);
	}

	diff_levenshtein(diffs) {
		this._isReady();
		const diffsPtr = this._serializeDiffList(diffs);
		const ret = this._exports.diffLevenshtein(diffsPtr, diffs.length);
		this._exports.freeDiffList(diffsPtr, diffs.length);

		if (ret == -1) {
			const error = this.get_last_error();
			throw new Error(error.message);
		}
		return ret;
	}

	diff_to_delta(diffs) {
		return this._diffToStringHelper("diffToDelta", diffs);
	}

	diff_from_delta(text, delta) {
		this._isReady();
		const textPtr = writeString(this._memory, this._alloc.bind(this), text);
		const deltaPtr = writeString(this._memory, this._alloc.bind(this), delta);
		const out_diffsPtr = this._alloc(4);

		const ret = this._exports.diffFromDelta(textPtr, deltaPtr, out_diffsPtr);
		this._free(textPtr);
		this._free(deltaPtr);

		if (ret === -1) {
			this._free(out_diffsPtr);
			const error = this.get_last_error();
			throw new Error(error.message);
		}

		const diffsPtr = readNumber(this._memory, out_diffsPtr, 'u32');
		this._free(out_diffsPtr);

		const diffs = this._deserializeDiffList(diffsPtr, ret);
		this._exports.freeDiffList(diffsPtr, ret);
		return diffs;
	}

	// ========== MATCH FUNCTIONS ==========

	match_main(text, pattern, loc) {
		this._isReady();
		const dmpPtr = writeStruct(this._memory, this._alloc.bind(this), DiffMatchPatchStruct, this.DiffMatchPatchSettings);
		const textPtr = writeString(this._memory, this._alloc.bind(this), text);
		const patternPtr = writeString(this._memory, this._alloc.bind(this), pattern);
		const ret = this._exports.matchMain(dmpPtr, textPtr, patternPtr, loc);
		this._free(dmpPtr);
		this._free(textPtr);
		this._free(patternPtr);

		if (ret == -2) {
			const error = this.get_last_error();
			throw new Error(error.message);
		}

		if (ret == -1) return null;
		return ret;
	}

	// ========== PATCH FUNCTIONS ==========

	patch_make(a, b, c) {
		if (typeof a === "string" && typeof b === "string" && c === undefined) {
			return this.patch_make_string_string(a, b);
		}
		if (Array.isArray(a) && b === undefined && c === undefined) {
			return this.patch_make_diffs(a);
		}
		if (typeof a === "string" && Array.isArray(b) && c === undefined) {
			return this.patch_make_string_diffs(a, b);
		}
		if (typeof a === "string" && typeof b === "string" && Array.isArray(c)) {
			return this.patch_make_string_string_diffs(a, b, c);
		}
		throw new Error("Invalid arguments to patch_make");
	}

	patch_make_string_string(text1, text2) {
		this._isReady();
		const dmpPtr = writeStruct(this._memory, this._alloc.bind(this), DiffMatchPatchStruct, this.DiffMatchPatchSettings);
		const text1Ptr = writeString(this._memory, this._alloc.bind(this), text1);
		const text2Ptr = writeString(this._memory, this._alloc.bind(this), text2);
		const out_patchesPtr = this._alloc(4);
		const ret = this._exports.patchMakeStringString(dmpPtr, text1Ptr, text2Ptr, out_patchesPtr);
		this._free(dmpPtr);
		this._free(text1Ptr);
		this._free(text2Ptr);

		if (ret === -1) {
			this._free(out_patchesPtr);
			const error = this.get_last_error();
			throw new Error(error.message);
		}

		const patchesPtr = readNumber(this._memory, out_patchesPtr, 'u32');
		this._free(out_patchesPtr);

		const patches = this._deserializePatchList(patchesPtr, ret);
		this._exports.freePatchList(patchesPtr, ret);
		return patches;
	}

	patch_make_diffs(diffs) {
		this._isReady();
		const dmpPtr = writeStruct(this._memory, this._alloc.bind(this), DiffMatchPatchStruct, this.DiffMatchPatchSettings);
		const diffsPtr = this._serializeDiffList(diffs);
		const out_patchesPtr = this._alloc(4);

		const ret = this._exports.patchMakeDiffs(dmpPtr, diffsPtr, diffs.length, out_patchesPtr);
		this._free(dmpPtr);

		if (ret === -1) {
			this._free(out_patchesPtr);
			const error = this.get_last_error();
			throw new Error(error.message);
		}

		const patchesPtr = readNumber(this._memory, out_patchesPtr, 'u32');
		this._free(out_patchesPtr);

		const patches = this._deserializePatchList(patchesPtr, ret);
		this._exports.freePatchList(patchesPtr, ret);
		return patches;
	}

	patch_make_string_diffs(text1, diffs) {
		this._isReady();
		const dmpPtr = writeStruct(this._memory, this._alloc.bind(this), DiffMatchPatchStruct, this.DiffMatchPatchSettings);
		const text1Ptr = writeString(this._memory, this._alloc.bind(this), text1);
		const diffsPtr = this._serializeDiffList(diffs);
		const out_patchesPtr = this._alloc(4);

		const ret = this._exports.patchMakeStringDiffs(dmpPtr, text1Ptr, diffsPtr, diffs.length, out_patchesPtr);
		this._free(dmpPtr);
		this._free(text1Ptr);

		if (ret === -1) {
			this._free(out_patchesPtr);
			const error = this.get_last_error();
			throw new Error(error.message);
		}

		const patchesPtr = readNumber(this._memory, out_patchesPtr, 'u32');
		this._free(out_patchesPtr);

		const patches = this._deserializePatchList(patchesPtr, ret);
		this._exports.freePatchList(patchesPtr, ret);
		return patches;
	}

	patch_make_string_string_diffs(text1, text2, diffs) {
		this._isReady();
		const dmpPtr = writeStruct(this._memory, this._alloc.bind(this), DiffMatchPatchStruct, this.DiffMatchPatchSettings);
		const text1Ptr = writeString(this._memory, this._alloc.bind(this), text1);
		const text2Ptr = writeString(this._memory, this._alloc.bind(this), text2);
		const diffsPtr = this._serializeDiffList(diffs);
		const out_patchesPtr = this._alloc(4);

		const ret = this._exports.patchMakeStringStringDiffs(dmpPtr, text1Ptr, text2Ptr, diffsPtr, diffs.length, out_patchesPtr);
		this._free(dmpPtr);
		this._free(text1Ptr);
		this._free(text2Ptr);

		if (ret === -1) {
			this._free(out_patchesPtr);
			const error = this.get_last_error();
			throw new Error(error.message);
		}

		const patchesPtr = readNumber(this._memory, out_patchesPtr, 'u32');
		this._free(out_patchesPtr);

		const patches = this._deserializePatchList(patchesPtr, ret);
		this._exports.freePatchList(patchesPtr, ret);
		return patches;
	}

	patch_deep_copy(patches) {
		// No need to call WASM - just deep copy in JS since we're already copying on every call
		return JSON.parse(JSON.stringify(patches));
	}

	patch_apply(patches, text) {
		this._isReady();
		const dmpPtr = writeStruct(this._memory, this._alloc.bind(this), DiffMatchPatchStruct, this.DiffMatchPatchSettings);
		const patchesPtr = this._serializePatchList(patches);
		const textPtr = writeString(this._memory, this._alloc.bind(this), text);
		const out_appliedPtr = this._alloc(4);

		const ret = this._exports.patchApply(dmpPtr, patchesPtr, patches.length, textPtr, out_appliedPtr);
		this._free(dmpPtr);
		this._free(textPtr);

		const appliedPtr = readNumber(this._memory, out_appliedPtr, 'u32');
		this._free(out_appliedPtr);

		if (ret === 0) {
			const error = this.get_last_error();
			throw new Error(error.message);
		}

		const resultText = readString(this._memory, ret);
		this._exports.freeString(ret);

		const appliedArray = [];
		const appliedView = new Uint8Array(this._memory.buffer, appliedPtr, patches.length);
		for (let i = 0; i < patches.length; i++) {
			appliedArray.push(appliedView[i] !== 0);
		}

		return [resultText, appliedArray];
	}

	patch_add_padding(patches) {
		this._isReady();
		const dmpPtr = writeStruct(this._memory, this._alloc.bind(this), DiffMatchPatchStruct, this.DiffMatchPatchSettings);
		const patchesPtr = this._serializePatchList(patches);
		const out_patchesPtr = this._alloc(4);
		const out_patches_lenPtr = this._alloc(4);

		const ret = this._exports.patchAddPadding(dmpPtr, patchesPtr, patches.length, out_patchesPtr, out_patches_lenPtr);
		this._free(dmpPtr);

		const newPatchesPtr = readNumber(this._memory, out_patchesPtr, 'u32');
		const newPatchesLen = readNumber(this._memory, out_patches_lenPtr, 'i32');
		this._free(out_patchesPtr);
		this._free(out_patches_lenPtr);

		if (ret === 0) {
			const error = this.get_last_error();
			throw new Error(error.message);
		}

		const padding = readString(this._memory, ret);
		this._exports.freeString(ret);

		const newPatches = this._deserializePatchList(newPatchesPtr, newPatchesLen);
		this._exports.freePatchList(newPatchesPtr, newPatchesLen);

		return [padding, newPatches];
	}

	patch_split_max(patches) {
		this._isReady();
		const dmpPtr = writeStruct(this._memory, this._alloc.bind(this), DiffMatchPatchStruct, this.DiffMatchPatchSettings);
		const patchesPtr = this._serializePatchList(patches);
		const out_patchesPtr = this._alloc(4);
		const out_patches_lenPtr = this._alloc(4);

		const ret = this._exports.patchSplitMax(dmpPtr, patchesPtr, patches.length, out_patchesPtr, out_patches_lenPtr);
		this._free(dmpPtr);

		const newPatchesPtr = readNumber(this._memory, out_patchesPtr, 'u32');
		const newPatchesLen = readNumber(this._memory, out_patches_lenPtr, 'i32');
		this._free(out_patchesPtr);
		this._free(out_patches_lenPtr);

		if (ret === -1) {
			const error = this.get_last_error();
			throw new Error(error.message);
		}

		const newPatches = this._deserializePatchList(newPatchesPtr, newPatchesLen);
		this._exports.freePatchList(newPatchesPtr, newPatchesLen);
		return newPatches;
	}

	patch_to_text(patches) {
		this._isReady();
		const patchesPtr = this._serializePatchList(patches);
		const ret = this._exports.patchToText(patchesPtr, patches.length);

		if (ret === 0) {
			const error = this.get_last_error();
			throw new Error(error.message);
		}

		const text = readString(this._memory, ret);
		this._exports.freeString(ret);
		return text;
	}

	patch_from_text(text) {
		this._isReady();
		const textPtr = writeString(this._memory, this._alloc.bind(this), text);
		const out_patchesPtr = this._alloc(4);

		const ret = this._exports.patchFromText(textPtr, out_patchesPtr);
		this._free(textPtr);

		if (ret === -1) {
			this._free(out_patchesPtr);
			const error = this.get_last_error();
			throw new Error(error.message);
		}

		const patchesPtr = readNumber(this._memory, out_patchesPtr, 'u32');
		this._free(out_patchesPtr);

		const patches = this._deserializePatchList(patchesPtr, ret);
		this._exports.freePatchList(patchesPtr, ret);
		return patches;
	}

	patch_obj_to_string(patch) {
		this._isReady();
		const patchPtr = writeStruct(this._memory, this._alloc.bind(this), PatchStruct, {
			start1: patch.start1,
			start2: patch.start2,
			length1: patch.length1,
			length2: patch.length2,
			diffs_len: patch.diffs.length,
			diffs: this._serializeDiffList(patch.diffs)
		});

		const ret = this._exports.patchObjToString(patchPtr);
		this._free(patchPtr);

		if (ret === 0) {
			const error = this.get_last_error();
			throw new Error(error.message);
		}

		const text = readString(this._memory, ret);
		this._exports.freeString(ret);
		return text;
	}

	// ========== HELPER FUNCTIONS ==========

	_diffCleanupHelper(fnName, diffs) {
		this._isReady();
		const diffsPtr = this._serializeDiffList(diffs);
		const out_diffsPtr = writeNumber(this._memory, this._alloc.bind(this), diffsPtr, 'u32');

		const ret = this._exports[fnName](out_diffsPtr, diffs.length);

		if (ret == -1) {
			this._free(out_diffsPtr);
			const error = this.get_last_error();
			throw new Error(error.message);
		}

		const newDiffsPtr = readNumber(this._memory, out_diffsPtr, 'u32');
		this._free(out_diffsPtr);

		const result = this._deserializeDiffList(newDiffsPtr, ret);
		this._exports.freeDiffList(newDiffsPtr, ret);
		return result;
	}

	_diffToStringHelper(fnName, diffs) {
		this._isReady();
		const diffsPtr = this._serializeDiffList(diffs);
		const ret = this._exports[fnName](diffsPtr, diffs.length);
		this._exports.freeDiffList(diffsPtr, diffs.length);

		if (ret === 0) {
			const error = this.get_last_error();
			throw new Error(error.message);
		}

		const result = readString(this._memory, ret);
		this._exports.freeString(ret);
		return result;
	}

	_serializeDiffList(diffs) {
		const diffsPtr = this._alloc(DiffStruct.size * diffs.length);
		for (let i = 0; i < diffs.length; i++) {
			const offset = diffsPtr + (i * DiffStruct.size);
			writeStruct(this._memory, this._alloc.bind(this), DiffStruct, diffs[i], offset);
		}
		return diffsPtr;
	}

	_deserializeDiffList(ptr, count) {
		const diffs = [];
		for (let i = 0; i < count; i++) {
			const offset = ptr + (i * DiffStruct.size);
			diffs.push(DiffStruct.deserialize(this._memory, offset));
		}
		return diffs;
	}

	_serializePatchList(patches) {
		const patchesPtr = this._alloc(PatchStruct.size * patches.length);
		for (let i = 0; i < patches.length; i++) {
			const offset = patchesPtr + (i * PatchStruct.size);
			const diffsPtr = this._serializeDiffList(patches[i].diffs);
			writeStruct(this._memory, this._alloc.bind(this), PatchStruct, {
				start1: patches[i].start1,
				start2: patches[i].start2,
				length1: patches[i].length1,
				length2: patches[i].length2,
				diffs_len: patches[i].diffs.length,
				diffs: diffsPtr
			}, offset);
		}
		return patchesPtr;
	}

	_deserializePatchList(ptr, count) {
		const patches = [];
		for (let i = 0; i < count; i++) {
			const offset = ptr + (i * PatchStruct.size);
			const patch = PatchStruct.deserialize(this._memory, offset);
			patch.diffs = this._deserializeDiffList(patch.diffs, patch.diffs_len);
			patches.push(patch);
		}
		return patches;
	}
}

///////////

// Type sizes in bytes
const TYPE_SIZES = {
	i8: 1, u8: 1,
	i16: 2, u16: 2,
	i32: 4, u32: 4,
	i64: 8, u64: 8,
	f32: 4, f64: 8,
	ptr: 4,
	string: 4,
};

// Alignment requirements
const TYPE_ALIGNMENTS = {
	i8: 1, u8: 1,
	i16: 2, u16: 2,
	i32: 4, u32: 4,
	i64: 8, u64: 8,
	f32: 4, f64: 8,
	ptr: 4,
	string: 4,
};

// Read a number from WASM memory
function readNumber(memory, ptr, type) {
	const view = new DataView(memory.buffer, ptr);
	switch (type) {
		case 'i8': return view.getInt8(0);
		case 'u8': return view.getUint8(0);
		case 'i16': return view.getInt16(0, true);
		case 'u16': return view.getUint16(0, true);
		case 'i32': return view.getInt32(0, true);
		case 'u32': return view.getUint32(0, true);
		case 'i64': return view.getBigInt64(0, true);
		case 'u64': return view.getBigUint64(0, true);
		case 'f32': return view.getFloat32(0, true);
		case 'f64': return view.getFloat64(0, true);
		case 'ptr': return view.getUint32(0, true);
		default: throw new Error(`Unknown type: ${type}`);
	}
}

// Write a number to WASM memory and return the pointer
function writeNumber(memory, alloc, value, type) {
	const size = TYPE_SIZES[type];
	if (!size) throw new Error(`Unknown type: ${type}`);

	const ptr = alloc(size);
	const view = new DataView(memory.buffer, ptr);

	switch (type) {
		case 'i8': view.setInt8(0, value); break;
		case 'u8': view.setUint8(0, value); break;
		case 'i16': view.setInt16(0, value, true); break;
		case 'u16': view.setUint16(0, value, true); break;
		case 'i32': view.setInt32(0, value, true); break;
		case 'u32': view.setUint32(0, value, true); break;
		case 'i64': view.setBigInt64(0, BigInt(value), true); break;
		case 'u64': view.setBigUint64(0, BigInt(value), true); break;
		case 'f32': view.setFloat32(0, value, true); break;
		case 'f64': view.setFloat64(0, value, true); break;
		case 'ptr': view.setUint32(0, value, true); break;
		default: throw new Error(`Unknown type: ${type}`);
	}

	return ptr;
}

// Read null-terminated string from WASM memory
function readString(memory, ptr) {
	const bytes = new Uint8Array(memory.buffer);
	let end = ptr;
	while (bytes[end] !== 0 && (end - ptr) <= 100_000) end++;
	return new TextDecoder().decode(bytes.subarray(ptr, end));
}

// Write string to WASM memory and return pointer
function writeString(memory, alloc, string) {
	const encoder = new TextEncoder();
	const bytes = encoder.encode(string);
	const ptr = alloc(bytes.length + 1);
	const memoryBytes = new Uint8Array(memory.buffer);
	memoryBytes.set(bytes, ptr);
	memoryBytes[ptr + bytes.length] = 0;
	return ptr;
}

// Write a struct to WASM memory and return pointer (or use provided pointer)
function writeStruct(memory, alloc, structDef, obj, ptr = null) {
	if (ptr === null) {
		ptr = alloc(structDef.size);
	}

	for (const field of structDef.fields) {
		const { name, type, offset } = field;
		const value = obj[name];

		if (value === undefined) continue;

		const fieldPtr = ptr + offset;

		if (type === 'string') {
			let strPtr;
			if (typeof value === 'string') {
				strPtr = writeString(memory, alloc, value);
			} else if (typeof value === 'number') {
				strPtr = value;
			} else {
				strPtr = 0;
			}
			writeNumber(memory, () => fieldPtr, strPtr, 'u32');
		} else {
			writeNumber(memory, () => fieldPtr, value, type);
		}
	}

	return ptr;
}

class StructDefinition {
	constructor(fields) {
		this.fields = Array.isArray(fields) ? fields : Object.entries(fields);
		this.layout = this._calculateLayout();
		this.size = this.layout.size;
		this.alignment = this.layout.alignment;
	}

	_calculateLayout() {
		const fields = [];
		let offset = 0;
		let maxAlign = 1;

		for (const [name, type] of this.fields) {
			const size = TYPE_SIZES[type];
			const align = TYPE_ALIGNMENTS[type];

			if (!size || !align) {
				throw new Error(`Unknown type: ${type}`);
			}

			maxAlign = Math.max(maxAlign, align);
			const padding = (align - (offset % align)) % align;
			offset += padding;

			fields.push({ name, type, offset, size });
			offset += size;
		}

		const totalPadding = (maxAlign - (offset % maxAlign)) % maxAlign;
		const totalSize = offset + totalPadding;

		return { fields, size: totalSize, alignment: maxAlign };
	}

	deserialize(memory, ptr) {
		const obj = {};

		for (const field of this.layout.fields) {
			const { name, type, offset } = field;
			const fieldPtr = ptr + offset;

			if (type === 'string') {
				const strPtr = readNumber(memory, fieldPtr, 'u32');
				obj[name] = strPtr !== 0 ? readString(memory, strPtr) : null;
			} else {
				obj[name] = readNumber(memory, fieldPtr, type);
			}
		}

		return obj;
	}
}

const ErrorInfoStruct = new StructDefinition([
	['source', 'u32'],
	['message', 'string'],
]);

const DiffMatchPatchStruct = new StructDefinition([
	["diff_timeout", "f32"],
	["diff_edit_cost", "u16"],
	["match_threshold", "f32"],
	["match_distance", "u32"],
	["patch_delete_threshold", "f32"],
	["patch_margin", "u16"],
]);

const DiffStruct = new StructDefinition([
	["operation", "i32"],
	["text", "string"],
]);

const PatchStruct = new StructDefinition([
	["start1", "i32"],
	["start2", "i32"],
	["length1", "i32"],
	["length2", "i32"],
	["diffs_len", "i32"],
	["diffs", "u32"],
]);

export { DiffMatchPatch };
