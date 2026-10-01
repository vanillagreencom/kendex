import { closeSync, createReadStream, openSync, readSync } from "node:fs";
import { StringDecoder } from "node:string_decoder";

/** Stream records off the input path. Index reads skip oversized records;
 * an action can read a complete prompt and stop at its selected entry. */
export async function forEachSessionJsonlLineAsync(sessionPath: string, onLine: (line: string) => unknown, signal: AbortSignal, options?: { maxLineChars: number }): Promise<void> {
	const stream = createReadStream(sessionPath, { signal, highWaterMark: 64 * 1024 });
	const decoder = new StringDecoder("utf8");
	const maxLineChars = options?.maxLineChars ?? 2 * 1024 * 1024;
	let pending = "";
	let skipping = false;
	try {
		for await (const chunk of stream) {
			signal.throwIfAborted();
			const text = decoder.write(chunk);
			let start = 0;
			for (;;) {
				const end = text.indexOf("\n", start);
				const part = text.slice(start, end < 0 ? undefined : end);
				if (!skipping && pending.length + part.length <= maxLineChars) pending += part;
				else { pending = ""; skipping = true; }
				if (end < 0) break;
				if (!skipping && onLine(pending.endsWith("\r") ? pending.slice(0, -1) : pending) === false) return;
				pending = "";
				skipping = false;
				start = end + 1;
			}
		}
		pending += decoder.end();
		if (!skipping && pending.length > 0) onLine(pending.endsWith("\r") ? pending.slice(0, -1) : pending);
	} finally {
		stream.destroy();
	}
}

export function forEachSessionJsonlLine(sessionPath: string, onLine: (line: string) => void, chunkSize = 64 * 1024): void {
	const fd = openSync(sessionPath, "r");
	const buffer = Buffer.allocUnsafe(Math.max(1, Math.floor(chunkSize)));
	const decoder = new StringDecoder("utf8");
	let pending = "";
	try {
		for (;;) {
			const bytesRead = readSync(fd, buffer, 0, buffer.length, null);
			if (bytesRead === 0) break;
			pending += decoder.write(buffer.subarray(0, bytesRead));
			let start = 0;
			for (;;) {
				const newline = pending.indexOf("\n", start);
				if (newline < 0) {
					pending = pending.slice(start);
					break;
				}
				const line = pending.slice(start, newline);
				onLine(line.endsWith("\r") ? line.slice(0, -1) : line);
				start = newline + 1;
			}
		}
		pending += decoder.end();
		if (pending.length > 0) onLine(pending.endsWith("\r") ? pending.slice(0, -1) : pending);
	} finally {
		closeSync(fd);
	}
}
