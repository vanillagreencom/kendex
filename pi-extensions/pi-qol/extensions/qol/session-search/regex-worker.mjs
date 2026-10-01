import { parentPort } from "node:worker_threads";

// The parent owns the deadline and terminates this worker even when exec
// never returns. Neither prompt matching nor snippet matching runs in Pi.
parentPort.on("message", ({ source, texts }) => {
	const regex = new RegExp(source, "i");
	parentPort.postMessage({ status: "matched", matches: texts.map((text) => {
		const match = regex.exec(text);
		return match ? { index: match.index, length: match[0].length } : null;
	}) });
});
parentPort.postMessage({ status: "ready" });