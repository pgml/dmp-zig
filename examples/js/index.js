import { DiffMatchPatch } from "./dmp.mjs"

const output = document.querySelector("#output");
const input = document.querySelector("#input");
const button = document.querySelector("button");
const warnings = document.querySelector("pre#logs");

new DiffMatchPatch(fetch("/diffmatchpatch.wasm")).readyPromise.then(dmp => {
	dmp.onError = (err) => log(`func ${err.source} errored with: ${err.message}`)
	window.dmp = dmp;
})

function log(text) {
	warnings.innerText = text + "\n" + warnings.innerText;
}
