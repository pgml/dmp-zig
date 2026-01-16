
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
		const errInfoPtr = this._alloc(ErrorInfoStruct.getSize());
		this._exports.getLastError(errInfoPtr);
		const errInfo = ErrorInfoStruct.deserialize(this._memory, errInfoPtr);
		// a bit more expensive then need, but since I don't want to track lifetimes, we are immediately freeing 
		this._free(errInfoPtr);
		return errInfo;
	}

	_get_default_dmp() {
		this._isReady();
		const dmpPtr = this._alloc(DiffMatchPatchStruct.getSize());
		this._exports.getDefaultDMP(dmpPtr);
		const dmp = DiffMatchPatchStruct.deserialize(this._memory, dmpPtr);
		this._free(dmpPtr);
		return dmp;
	}

	//

	match_main(text, pattern, loc) {
		this._isReady();
		const dmpPtr = this._alloc(DiffMatchPatchStruct.getSize());
		DiffMatchPatchStruct.serialize(this._memory, (l) => this._alloc(l), dmpPtr, this.DiffMatchPatchSettings);
		const textPtr = writeString(this._memory, (l) => this._alloc(l), text);
		const patternPtr = writeString(this._memory, (l) => this._alloc(l), pattern);
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

	//

	patch_make(a, b, c) {
		if (typeof a === "string" && typeof b === "string" && c == undefined) return patch_make_string_string(a, b);

		if (typeof a === "object" && b === undefined && c == undefined) { } // list of diffs
		if (typeof a === "string" && typeof b === "object" && c == undefined) { } // string and list of diffs
		if (typeof a === "string" && typeof b === "string" && typeof c == "object") { } // string, string and list of diffs
		throw "TODO"
	}
	patch_make_string_string(text1, text2) {
		this._isReady();
		const dmpPtr = this._alloc(DiffMatchPatchStruct.getSize());
		DiffMatchPatchStruct.serialize(this._memory, (l) => this._alloc(l), dmpPtr, this.DiffMatchPatchSettings);
		const text1Ptr = writeString(this._memory, (l) => this._alloc(l), text1);
		const text2Ptr = writeString(this._memory, (l) => this._alloc(l), text2);
		const out_patchesCountPtr = this._alloc(2);
		const ret = this._exports.patchMakeStringString(dmpPtr, text1Ptr, text2Ptr, out_patchesCountPtr);
		this._free(dmpPtr);
		this._free(text1Ptr);
		this._free(text2Ptr);

		const view = new DataView(this._memory.buffer, out_patchesCountPtr, this.layout.size);
		const patchCount = view.getInt16(offset, true);
		this._free(out_patchesCountPtr);

		if (ret == 0 || patchCount == -1) return null;

		let patchList = []
		let loc = ret;
		for (let i = 0; i < patchCount; i++) {
			// TODO: maybe extract to 
		}

		this._exports.freePatchList(ret, patchCount);

		return patchList;
	}
	// patch_deep_copy() { } -- scip

	patch_apply() { }
	patch_add_padding() { }
	patch_split_max() { }
	patch_to_text() { }
	patch_from_text() { }
	patch_obj_to_string() { }

	//
}


// exports

// a bit more expensive then neede, but since I dont want to track lifetimes, we are immediately freeing 

// function alloc_string() { }
// function free_string() { }
// function free_patch_list() { }
// function free_diffs_list() { }

function diff_diff_main() { }

function diff_common_prefix() { }
function diff_common_suffix() { }
function diff_cleanup_semantic() { }
function diff_cleanup_semantic_lossless() { }
function diff_cleanup_efficiency() { }
function diff_cleanup_merge() { }
function diff_xindex() { }
function diff_pretty_html() { }
function diff_pretty_text() { }
function diff_text1() { }
function diff_text2() { }
function diff_levenshtein() { }
function diff_to_delta() { }
function diff_from_delta() { }


///////////

// Type sizes in bytes
const TYPE_SIZES = {
	i8: 1, u8: 1,
	i16: 2, u16: 2,
	i32: 4, u32: 4,
	i64: 8, u64: 8,
	f32: 4, f64: 8,
	ptr: 4, // 32-bit pointer, change to 8 for 64-bit
	string: 4, // string is a pointer to null-terminated string
};

// Alignment requirements
const TYPE_ALIGNMENTS = {
	i8: 1, u8: 1,
	i16: 2, u16: 2,
	i32: 4, u32: 4,
	i64: 8, u64: 8,
	f32: 4, f64: 8,
	ptr: 4,
	string: 4, // aligned like pointers
};

// Helper to read null-terminated string from memory
function readString(memory, ptr) {
	const bytes = new Uint8Array(memory.buffer);
	let end = ptr;
	while (bytes[end] !== 0 && (end - ptr) <= 100_000) end++; // with safeguard
	return new TextDecoder().decode(bytes.subarray(ptr, end));
}

// Helper to allocate and write string to WASM memory
// You need to provide your own alloc function
function writeString(memory, alloc, string) {
	const encoder = new TextEncoder();
	const bytes = encoder.encode(string);
	const ptr = alloc(bytes.length + 1); // +1 for null terminator
	const memoryBytes = new Uint8Array(memory.buffer);
	memoryBytes.set(bytes, ptr);
	memoryBytes[ptr + bytes.length] = 0; // null terminator
	return ptr;
}

class StructDefinition {
	constructor(fields) {
		// Accept either array of [name, type] or object
		this.fields = Array.isArray(fields)
			? fields
			: Object.entries(fields);
		this.layout = this._calculateLayout();
	}

	_calculateLayout() {
		const layout = [];
		let offset = 0;
		let maxAlign = 1;

		for (const [name, type] of this.fields) {
			const size = TYPE_SIZES[type];
			const align = TYPE_ALIGNMENTS[type];

			if (!size || !align) {
				throw new Error(`Unknown type: ${type}`);
			}

			maxAlign = Math.max(maxAlign, align);

			// Add padding for alignment
			const padding = (align - (offset % align)) % align;
			offset += padding;

			layout.push({ name, type, offset, size });
			offset += size;
		}

		// Align total size to largest alignment
		const totalPadding = (maxAlign - (offset % maxAlign)) % maxAlign;
		const totalSize = offset + totalPadding;

		return { fields: layout, size: totalSize, alignment: maxAlign };
	}

	deserialize(memory, ptr) {
		const view = new DataView(memory.buffer, ptr, this.layout.size);
		const obj = {};

		for (const field of this.layout.fields) {
			const { name, type, offset } = field;

			switch (type) {
				case 'i8': obj[name] = view.getInt8(offset); break;
				case 'u8': obj[name] = view.getUint8(offset); break;
				case 'i16': obj[name] = view.getInt16(offset, true); break;
				case 'u16': obj[name] = view.getUint16(offset, true); break;
				case 'i32': obj[name] = view.getInt32(offset, true); break;
				case 'u32': obj[name] = view.getUint32(offset, true); break;
				case 'i64': obj[name] = view.getBigInt64(offset, true); break;
				case 'u64': obj[name] = view.getBigUint64(offset, true); break;
				case 'f32': obj[name] = view.getFloat32(offset, true); break;
				case 'f64': obj[name] = view.getFloat64(offset, true); break;
				case 'ptr': obj[name] = view.getUint32(offset, true); break;
				case 'string': {
					const strPtr = view.getUint32(offset, true);
					obj[name] = strPtr !== 0 ? readString(memory, strPtr) : null;
					break;
				}
			}
		}

		return obj;
	}

	serialize(memory, alloc, ptr, obj) {
		const view = new DataView(memory.buffer, ptr, this.layout.size);

		for (const field of this.layout.fields) {
			const { name, type, offset } = field;
			const value = obj[name];

			if (value === undefined) continue;

			switch (type) {
				case 'i8': view.setInt8(offset, value); break;
				case 'u8': view.setUint8(offset, value); break;
				case 'i16': view.setInt16(offset, value, true); break;
				case 'u16': view.setUint16(offset, value, true); break;
				case 'i32': view.setInt32(offset, value, true); break;
				case 'u32': view.setUint32(offset, value, true); break;
				case 'i64': view.setBigInt64(offset, BigInt(value), true); break;
				case 'u64': view.setBigUint64(offset, BigInt(value), true); break;
				case 'f32': view.setFloat32(offset, value, true); break;
				case 'f64': view.setFloat64(offset, value, true); break;
				case 'ptr': view.setUint32(offset, value, true); break;
				case 'string': {
					// If value is a string, allocate and write it
					if (typeof value === 'string') {
						const strPtr = writeString(memory, alloc, value);
						view.setUint32(offset, strPtr, true);
					}
					// Otherwise treat value as a pointer
					else if (typeof value === 'number') {
						view.setUint32(offset, value, true);
					}
					// If null/undefined, write 0
					else {
						view.setUint32(offset, 0, true);
					}
					break;
				}
			}
		}
	}

	getSize() {
		return this.layout.size;
	}

	getAlignment() {
		return this.layout.alignment;
	}

	printLayout() {
		console.log(`Struct size: ${this.layout.size} bytes, alignment: ${this.layout.alignment}`);
		console.log('Layout:');
		for (const field of this.layout.fields) {
			console.log(`  ${field.name.padEnd(15)} ${field.type.padEnd(5)} offset: ${field.offset}, size: ${field.size}`);
		}
	}
}

// TODO: enums
const ErrorInfoStruct = new StructDefinition([
	['source', 'u32'],
	['message', 'string'],
]);

const DiffMatchPatchStruct = new StructDefinition([
	["diff_timeout", "f32"],
	["diff_edit_cost", "u16"],
	["match_threshold", "f32"],
	["match_distance", "i16"],
	["patch_delete_threshold", "f32"],
	["patch_margin", "u16"],
]);

const DiffStruct = new StructDefinition([
	["operation", "i16"],
	["text", "string"],
]);

const PatchStruct = new StructDefinition([
	["start1", "i16"],
	["start2", "i16"],
	["length1", "i16"],
	["length2", "i16"],
	["diffs_len", "i16"],
	["diffs", "u32"], // pointer to list of DiffStruct
]);

export { DiffMatchPatch };
