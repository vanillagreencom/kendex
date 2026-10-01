import { open } from "node:fs/promises";
import type { ManagedTask } from "./types.js";

interface OutputTail {
	text: string;
	truncated: boolean;
}

interface Tail extends OutputTail {
	logFile: string;
	maxBytes: number;
	mtimeMs: number;
	ctimeMs: number;
	size: number;
	ino: number;
}

/** Asynchronous log tails owned by the task that consumes them. */
export function createTaskOutputReader(report: (logFile: string, error: string) => void) {
	let tails = new WeakMap<ManagedTask, { tail?: Tail; pending?: Promise<OutputTail> }>();
	return {
		async read(task: ManagedTask, maxBytes: number): Promise<string> {
			return (await this.readTail(task, maxBytes)).text;
		},
		/** Keep disk omission information for consumers that format a bounded excerpt. */
		async readTail(task: ManagedTask, maxBytes: number): Promise<OutputTail> {
			if (task.output.length > 0) return { text: task.output, truncated: false };
			let state = tails.get(task);
			if (!state) {
				state = {};
				tails.set(task, state);
			}
			if (state.pending) {
				await state.pending;
				// A concurrent caller can ask for a different tail limit.
				return this.readTail(task, maxBytes);
			}
			const owned = state;
			const lengthLimit = Math.max(1, Math.floor(maxBytes));
			owned.pending = (async () => {
				let file: Awaited<ReturnType<typeof open>> | undefined;
				try {
					file = await open(task.logFile, "r");
					const { size, mtimeMs, ctimeMs, ino } = await file.stat();
					const tail = owned.tail;
					if (tail?.logFile === task.logFile && tail.maxBytes === lengthLimit && tail.size === size
						&& tail.mtimeMs === mtimeMs && tail.ctimeMs === ctimeMs && tail.ino === ino) return tail;
					const length = Math.min(size, lengthLimit);
					const buffer = Buffer.alloc(length);
					let read = 0;
					while (read < length) {
						const { bytesRead } = await file.read(buffer, read, length - read, size - length + read);
						if (bytesRead === 0) break;
						read += bytesRead;
					}
					// A byte-limited tail can start inside a UTF-8 character.
					const text = buffer.subarray(0, read).toString("utf8").replace(/^\uFFFD+/, "");
					owned.tail = { logFile: task.logFile, maxBytes: lengthLimit, size, mtimeMs, ctimeMs, ino, text, truncated: size > read };
					return owned.tail;
				} finally {
					if (file) await file.close();
				}
			})().catch((error: unknown) => {
				if ((error as NodeJS.ErrnoException).code === "ENOENT") return { text: "", truncated: false };
				const reason = error instanceof Error ? error.message : String(error);
				report(task.logFile, reason);
				return { text: `[log unreadable: ${reason}]`, truncated: false };
			});
			try {
				return await owned.pending;
			} finally {
				owned.pending = undefined;
			}
		},
		clear(): void { tails = new WeakMap(); },
	};
}
