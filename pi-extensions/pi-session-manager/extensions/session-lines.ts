import { closeSync, openSync, readSync } from "node:fs";
import { StringDecoder } from "node:string_decoder";

export function forEachSessionJsonlLine(sessionPath: string, onLine: (line: string) => void, chunkSize = 64 * 1024): void {
	const fd = openSync(sessionPath, "r");
	const buffer = Buffer.allocUnsafe(Math.max(1, Math.floor(chunkSize)));
	const decoder = new StringDecoder("utf8");
	// The unfinished line's pieces, joined once its newline arrives: each chunk is
	// scanned once, so a record spanning many chunks costs its length, not its square.
	let pieces: string[] = [];
	const emit = (line: string) => onLine(line.endsWith("\r") ? line.slice(0, -1) : line);
	const scan = (text: string) => {
		let start = 0;
		for (;;) {
			const newline = text.indexOf("\n", start);
			if (newline < 0) {
				if (start < text.length) pieces.push(text.slice(start));
				return;
			}
			pieces.push(text.slice(start, newline));
			emit(pieces.join(""));
			pieces = [];
			start = newline + 1;
		}
	};
	try {
		for (;;) {
			const bytesRead = readSync(fd, buffer, 0, buffer.length, null);
			if (bytesRead === 0) break;
			scan(decoder.write(buffer.subarray(0, bytesRead)));
		}
		scan(decoder.end());
		if (pieces.length > 0) emit(pieces.join(""));
	} finally {
		closeSync(fd);
	}
}
