// Task log appends, batched and written off Pi's thread.
//
// A chunk of task output joins its log file's pending text; one timer per
// window writes every file's pending text with one asynchronous append per
// file, and a file has at most one write in flight. A file whose pending text
// reaches LOG_WRITE_NOW_BYTES with no write in flight is written at once,
// without the window. A file whose pending text reaches LOG_MAX_PENDING_BYTES
// while a write is in flight holds its producer: append() returns a promise
// that resolves when that text is taken for the next write, and the task
// pauses its output until then. A disk that keeps up loses no output; a write
// that stalls stalls the task, never grows memory. A failed write's bytes are
// counted, and a marker naming them and the error leads the next batch.
// flush() writes one file's pending text at once and drain() every file's,
// each waiting for the writes up to a deadline.

import { appendFile } from "node:fs/promises";

import { createCoalescedCall, type CoalescedCallTimers } from "./coalesce.js";
import { logBackgroundDiagnostic } from "./diagnostics.js";

/** Window between a first pending chunk and its write. */
export const LOG_FLUSH_DELAY_MS = 250;

/** Pending bytes that start a file's write at once when none is in flight. */
export const LOG_WRITE_NOW_BYTES = 1024 * 1024;

/** Pending bytes at which a file holds its producer until the write in flight ends. */
export const LOG_MAX_PENDING_BYTES = 4 * 1024 * 1024;

/** Longest a log flush or session shutdown waits for pending log text to be written. */
export const LOG_DRAIN_DEADLINE_MS = 2_000;

export function failedLogMarker(bytes: number, error: string): string {
	return `\n[log dropped ${bytes} bytes: log write failed: ${error}]\n`;
}

export interface LogWriter {
	/**
	 * Queue `text` for `file`. Returns null while the file can take more, or a
	 * promise that resolves once its pending text is taken for a write; the
	 * producer stops sending until then.
	 */
	append(file: string, text: string): Promise<void> | null;
	/**
	 * Write the file's pending text at once and wait for its writes, at most
	 * `deadlineMs`. Returns null when the file has no pending text and no write
	 * in flight, so it already holds every appended chunk. Resolves with the
	 * file in `unwritten` when its writes had not finished at the deadline.
	 */
	flush(file: string, deadlineMs: number): Promise<{ unwritten: string[] }> | null;
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
	/** Bytes failed writes lost since the last batch was taken, and the last error. */
	failed: { bytes: number; error: string } | null;
	writing: Promise<void> | null;
	/** The producer's hold while pending text is at the cap; released when that text is taken. */
	hold: { released: Promise<void>; release: () => void } | null;
}

interface Batch {
	text: string;
	/** Task output bytes the batch accounts for, the count in its marker included. */
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
	const flushWindow = createCoalescedCall(() => {
		for (const [file, queue] of queues) pump(file, queue);
	}, LOG_FLUSH_DELAY_MS, deps);

	function takeBatch(queue: FileQueue): Batch | null {
		const { failed, pendingBytes } = queue;
		if (queue.pending.length === 0 && !failed) return null;
		const text = (failed ? failedLogMarker(failed.bytes, failed.error) : "") + queue.pending.join("");
		queue.pending = [];
		queue.pendingBytes = 0;
		queue.failed = null;
		queue.hold?.release();
		queue.hold = null;
		return { text, outputBytes: pendingBytes + (failed?.bytes ?? 0) };
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
				if (queue.pendingBytes >= LOG_WRITE_NOW_BYTES) pump(file, queue);
				else if (queue.pending.length > 0) flushWindow.request();
				else if (!queue.failed && queues.get(file) === queue) queues.delete(file);
			});
		queue.writing = current;
	}

	function pump(file: string, queue: FileQueue): void {
		if (queue.writing) return;
		if (queue.pending.length === 0) {
			if (!queue.failed && queues.get(file) === queue) queues.delete(file);
			return;
		}
		const batch = takeBatch(queue);
		if (batch) startWrite(file, queue, batch);
	}

	// Takes the queue's batch, failure marker included, and returns the write to wait for.
	function writeNow(file: string, queue: FileQueue): Promise<void> | null {
		const batch = takeBatch(queue);
		if (batch) startWrite(file, queue, batch);
		return queue.writing;
	}

	async function waitForWrites(writes: { file: string; done: Promise<void> }[], deadlineMs: number): Promise<{ unwritten: string[] }> {
		const unwritten = new Set(writes.map(({ file }) => file));
		const written = Promise.all(writes.map(({ file, done }) => done.then(() => { unwritten.delete(file); })));
		let expire = () => {};
		const deadline = new Promise<void>((resolve) => { expire = resolve; });
		const timer = setTimer(() => expire(), deadlineMs);
		(timer as { unref?: () => void }).unref?.();
		await Promise.race([written, deadline]);
		clearTimer(timer);
		return { unwritten: [...unwritten] };
	}

	return {
		append(file, text) {
			if (!text) return null;
			let queue = queues.get(file);
			if (!queue) {
				queue = { pending: [], pendingBytes: 0, failed: null, writing: null, hold: null };
				queues.set(file, queue);
			}
			queue.pending.push(text);
			queue.pendingBytes += Buffer.byteLength(text, "utf8");
			if (!queue.writing && queue.pendingBytes >= LOG_WRITE_NOW_BYTES) {
				pump(file, queue);
				return null;
			}
			flushWindow.request();
			if (queue.pendingBytes < LOG_MAX_PENDING_BYTES) return null;
			if (!queue.hold) {
				let release = () => {};
				const released = new Promise<void>((resolve) => { release = resolve; });
				queue.hold = { released, release };
			}
			return queue.hold.released;
		},
		flush(file, deadlineMs) {
			const queue = queues.get(file);
			if (!queue) return null;
			const done = writeNow(file, queue);
			if (!done) return null;
			return waitForWrites([{ file, done }], deadlineMs);
		},
		async drain(deadlineMs) {
			flushWindow.cancel();
			const writes: { file: string; done: Promise<void> }[] = [];
			for (const [file, queue] of queues) {
				const done = writeNow(file, queue);
				if (done) writes.push({ file, done });
			}
			if (writes.length === 0) return { unwritten: [] };
			return await waitForWrites(writes, deadlineMs);
		},
	};
}

/** The log writer every task of this Pi process shares. */
export const taskLogs = createLogWriter();
