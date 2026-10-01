import { open } from "node:fs/promises";
import { PROBE_CONCURRENCY } from "./probes.js";
import type { ManagedTask } from "./types.js";

interface OutputTail {
	text: string;
	truncated: boolean;
}

interface Tail extends OutputTail {
	logFile: string;
	maxChars: number;
	mtimeMs: number;
	ctimeMs: number;
	size: number;
	ino: number;
}

/** Asynchronous log tails owned by the task that consumes them. */
export function createTaskOutputReader(report: (logFile: string, error: string) => void, isCurrent: (task: ManagedTask) => boolean = () => true) {
	let tails = new WeakMap<ManagedTask, { tail?: Tail; pending?: Promise<OutputTail> }>();
	let active = 0;
	const queued: (() => void)[] = [];
	return {
		async read(task: ManagedTask, maxChars: number): Promise<string> {
			return (await this.readTail(task, maxChars)).text;
		},
		/** Keep disk omission information for consumers that format a bounded excerpt. */
		async readTail(task: ManagedTask, maxChars: number): Promise<OutputTail> {
			if (task.output.length > 0) return { text: task.output, truncated: false };
			let state = tails.get(task);
			if (!state) {
				state = {};
				tails.set(task, state);
			}
			if (state.pending) {
				await state.pending;
				if (tails.get(task) !== state || !isCurrent(task)) return { text: "", truncated: false };
				// A concurrent caller can ask for a different tail limit.
				return this.readTail(task, maxChars);
			}
			const owned = state;
			const lengthLimit = Math.max(1, Math.floor(maxChars));
			owned.pending = (async () => {
				const valid = () => tails.get(task) === owned && isCurrent(task);
				while (active >= PROBE_CONCURRENCY && valid()) await new Promise<void>((resolve) => queued.push(resolve));
				if (!valid()) return { text: "", truncated: false };
				active += 1;
				let file: Awaited<ReturnType<typeof open>> | undefined;
				try {
					file = await open(task.logFile, "r");
					const { size, mtimeMs, ctimeMs, ino } = await file.stat();
					const tail = owned.tail;
					if (tail?.logFile === task.logFile && tail.maxChars === lengthLimit && tail.size === size
						&& tail.mtimeMs === mtimeMs && tail.ctimeMs === ctimeMs && tail.ino === ino) return tail;
					// UTF-8 needs at most three bytes per UTF-16 code unit, plus one
					// when the suffix starts with the second half of a surrogate pair.
					const length = Math.min(size, 3 * lengthLimit + 1);
					const buffer = Buffer.alloc(length);
					let read = 0;
					while (read < length) {
						const { bytesRead } = await file.read(buffer, read, length - read, size - length + read);
						if (bytesRead === 0) break;
						read += bytesRead;
					}
					// Skip only a cut UTF-8 prefix, not a literal replacement character.
					let start = 0;
					if (size > length) while (start < read && (buffer[start] & 0xc0) === 0x80) start += 1;
					const decoded = buffer.subarray(start, read).toString("utf8");
					const text = decoded.slice(-lengthLimit);
					owned.tail = { logFile: task.logFile, maxChars: lengthLimit, size, mtimeMs, ctimeMs, ino, text, truncated: size > read || decoded.length > lengthLimit };
					return owned.tail;
				} finally {
					try { if (file) await file.close(); }
					finally { active -= 1; queued.shift()?.(); }
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
		clear(): void {
			tails = new WeakMap();
			// Old descriptors retain capacity until close, even across sessions.
			for (const wake of queued.splice(0)) wake();
		},
	};
}
