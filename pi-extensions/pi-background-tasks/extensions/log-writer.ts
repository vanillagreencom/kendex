// Task log appends, batched and written off Pi's thread.
//
// A chunk of task output joins its log file's pending text; one timer per
// window writes every file's pending text with one asynchronous append per
// file, and a file has at most one write in flight. Pending text per file is
// capped: the first chunk past the cap opens a gap, every later chunk joins it
// until the next batch is taken, and that batch ends with a marker line naming
// the dropped byte count, so a stalled disk costs log bytes, never unbounded
// memory. A failed write's bytes are counted the same way, and its marker leads
// the next batch. drain() writes what is pending when it is called and waits
// for it up to a deadline, for session shutdown.

import { appendFile } from "node:fs/promises";

import { createCoalescedCall, type CoalescedCallTimers } from "./coalesce.js";
import { logBackgroundDiagnostic } from "./diagnostics.js";

/** Window between a first pending chunk and its write. */
export const LOG_FLUSH_DELAY_MS = 250;

/** Pending bytes one log file may hold while its writes fall behind. */
export const LOG_MAX_PENDING_BYTES = 4 * 1024 * 1024;

/** Longest session shutdown waits for pending log text to be written. */
export const LOG_DRAIN_DEADLINE_MS = 2_000;

export const LOG_FELL_BEHIND_REASON = "log file writes fell behind the task's output";

export function droppedLogMarker(bytes: number, reason: string): string {
	return `\n[log dropped ${bytes} bytes: ${reason}]\n`;
}

export interface LogWriter {
	append(file: string, text: string): void;
	/**
	 * Write the text pending at the call and wait for it, at most `deadlineMs`.
	 * Text appended after the call waits for the next window. Resolves with the
	 * files whose writes had not finished at the deadline.
	 */
	drain(deadlineMs: number): Promise<{ unwritten: string[] }>;
}

export interface LogWriterDeps extends CoalescedCallTimers {
	append?: (file: string, text: string) => Promise<void>;
	onError?: (file: string, error: unknown) => void;
}

interface FileQueue {
	pending: string[];
	pendingBytes: number;
	/** Bytes dropped at the cap since the last batch was taken. */
	fellBehindBytes: number;
	/** Bytes failed writes lost since the last batch was taken, and the last error. */
	failed: { bytes: number; error: string } | null;
	writing: Promise<void> | null;
}

interface Batch {
	text: string;
	/** Task output bytes the batch accounts for, the counts in its markers included. */
	outputBytes: number;
}

export function createLogWriter(deps: LogWriterDeps = {}): LogWriter {
	const write = deps.append ?? ((file: string, text: string) => appendFile(file, text));
	const onError = deps.onError ?? ((file: string, error: unknown) => {
		logBackgroundDiagnostic("task log append failed", { file, error: error instanceof Error ? error.message : String(error) });
	});
	const setTimer = deps.setTimer ?? ((cb, ms) => setTimeout(cb, ms));
	const clearTimer = deps.clearTimer ?? ((handle) => clearTimeout(handle));
	const queues = new Map<string, FileQueue>();
	const flush = createCoalescedCall(() => {
		for (const [file, queue] of queues) pump(file, queue);
	}, LOG_FLUSH_DELAY_MS, deps);

	function takeBatch(queue: FileQueue): Batch | null {
		const { failed, fellBehindBytes, pendingBytes } = queue;
		if (queue.pending.length === 0 && fellBehindBytes === 0 && !failed) return null;
		const text = (failed ? droppedLogMarker(failed.bytes, `log write failed: ${failed.error}`) : "")
			+ queue.pending.join("")
			+ (fellBehindBytes > 0 ? droppedLogMarker(fellBehindBytes, LOG_FELL_BEHIND_REASON) : "");
		queue.pending = [];
		queue.pendingBytes = 0;
		queue.fellBehindBytes = 0;
		queue.failed = null;
		return { text, outputBytes: pendingBytes + fellBehindBytes + (failed?.bytes ?? 0) };
	}

	// Chains after the queue's write in flight, so a file never has two.
	function startWrite(file: string, queue: FileQueue, batch: Batch): void {
		const previous = queue.writing ?? Promise.resolve();
		const current: Promise<void> = previous
			.then(() => write(file, batch.text))
			.then(
				() => undefined,
				(error: unknown) => {
					const message = error instanceof Error ? error.message : String(error);
					queue.failed = { bytes: (queue.failed?.bytes ?? 0) + batch.outputBytes, error: message };
					onError(file, error);
				},
			)
			.then(() => {
				if (queue.writing !== current) return;
				queue.writing = null;
				// A failure marker alone waits for the file's next append or a
				// drain, so a disk that keeps failing is not retried on a timer.
				if (queue.pending.length > 0 || queue.fellBehindBytes > 0) flush.request();
				else if (!queue.failed && queues.get(file) === queue) queues.delete(file);
			});
		queue.writing = current;
	}

	function pump(file: string, queue: FileQueue): void {
		if (queue.writing) return;
		if (queue.pending.length === 0 && queue.fellBehindBytes === 0) {
			if (!queue.failed && queues.get(file) === queue) queues.delete(file);
			return;
		}
		const batch = takeBatch(queue);
		if (batch) startWrite(file, queue, batch);
	}

	return {
		append(file, text) {
			if (!text) return;
			let queue = queues.get(file);
			if (!queue) {
				queue = { pending: [], pendingBytes: 0, fellBehindBytes: 0, failed: null, writing: null };
				queues.set(file, queue);
			}
			const bytes = Buffer.byteLength(text, "utf8");
			if (queue.fellBehindBytes > 0 || queue.pendingBytes + bytes > LOG_MAX_PENDING_BYTES) {
				queue.fellBehindBytes += bytes;
			} else {
				queue.pending.push(text);
				queue.pendingBytes += bytes;
			}
			flush.request();
		},
		async drain(deadlineMs) {
			flush.cancel();
			const writes: { file: string; done: Promise<void> }[] = [];
			for (const [file, queue] of queues) {
				const batch = takeBatch(queue);
				if (batch) startWrite(file, queue, batch);
				if (queue.writing) writes.push({ file, done: queue.writing });
			}
			if (writes.length === 0) return { unwritten: [] };
			const unwritten = new Set(writes.map(({ file }) => file));
			const written = Promise.all(writes.map(({ file, done }) => done.then(() => { unwritten.delete(file); })));
			let expire = () => {};
			const deadline = new Promise<void>((resolve) => { expire = resolve; });
			const timer = setTimer(() => expire(), deadlineMs);
			(timer as { unref?: () => void }).unref?.();
			await Promise.race([written, deadline]);
			clearTimer(timer);
			return { unwritten: [...unwritten] };
		},
	};
}

/** The log writer every task of this Pi process shares. */
export const taskLogs = createLogWriter();
