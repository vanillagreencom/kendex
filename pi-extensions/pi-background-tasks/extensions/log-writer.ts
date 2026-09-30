// Task log appends, batched and written off Pi's thread.
//
// A chunk of task output joins its log file's pending text; one timer per
// window writes every file's pending text with one asynchronous append per
// file, and a file has at most one write in flight. Pending text per file is
// capped: past the cap a chunk is dropped and counted, and the next write
// ends with a marker line naming the dropped byte count, so a stalled disk
// costs log bytes, never unbounded memory. drain() writes everything pending
// and waits for it, for session shutdown.

import { appendFile } from "node:fs/promises";

import { createCoalescedCall, type CoalescedCallTimers } from "./coalesce.js";
import { logBackgroundDiagnostic } from "./diagnostics.js";

/** Window between a first pending chunk and its write. */
export const LOG_FLUSH_DELAY_MS = 250;

/** Pending bytes one log file may hold while its writes fall behind. */
export const LOG_MAX_PENDING_BYTES = 4 * 1024 * 1024;

export function droppedLogMarker(bytes: number): string {
	return `\n[log dropped ${bytes} bytes: log file writes fell behind the task's output]\n`;
}

export interface LogWriter {
	append(file: string, text: string): void;
	drain(): Promise<void>;
}

export interface LogWriterDeps extends CoalescedCallTimers {
	append?: (file: string, text: string) => Promise<void>;
	onError?: (file: string, error: unknown) => void;
}

interface FileQueue {
	pending: string[];
	pendingBytes: number;
	droppedBytes: number;
	writing: Promise<void> | null;
}

export function createLogWriter(deps: LogWriterDeps = {}): LogWriter {
	const write = deps.append ?? ((file: string, text: string) => appendFile(file, text));
	const onError = deps.onError ?? ((file: string, error: unknown) => {
		logBackgroundDiagnostic("task log append failed", { file, error: error instanceof Error ? error.message : String(error) });
	});
	const queues = new Map<string, FileQueue>();
	const flush = createCoalescedCall(() => {
		for (const [file, queue] of queues) void pump(file, queue);
	}, LOG_FLUSH_DELAY_MS, deps);

	function pump(file: string, queue: FileQueue): Promise<void> {
		if (queue.writing) return queue.writing;
		if (queue.pending.length === 0 && queue.droppedBytes === 0) {
			if (queues.get(file) === queue) queues.delete(file);
			return Promise.resolve();
		}
		const text = queue.pending.join("") + (queue.droppedBytes > 0 ? droppedLogMarker(queue.droppedBytes) : "");
		queue.pending = [];
		queue.pendingBytes = 0;
		queue.droppedBytes = 0;
		queue.writing = write(file, text)
			.catch((error: unknown) => onError(file, error))
			.then(() => {
				queue.writing = null;
				if (queue.pending.length > 0 || queue.droppedBytes > 0) flush.request();
				else if (queues.get(file) === queue) queues.delete(file);
			});
		return queue.writing;
	}

	return {
		append(file, text) {
			if (!text) return;
			let queue = queues.get(file);
			if (!queue) {
				queue = { pending: [], pendingBytes: 0, droppedBytes: 0, writing: null };
				queues.set(file, queue);
			}
			const bytes = Buffer.byteLength(text, "utf8");
			if (queue.pendingBytes + bytes > LOG_MAX_PENDING_BYTES) {
				queue.droppedBytes += bytes;
			} else {
				queue.pending.push(text);
				queue.pendingBytes += bytes;
			}
			flush.request();
		},
		async drain() {
			while (queues.size > 0) {
				flush.cancel();
				await Promise.all([...queues].map(([file, queue]) => pump(file, queue)));
			}
			flush.cancel();
		},
	};
}

/** The log writer every task of this Pi process shares. */
export const taskLogs = createLogWriter();
