// Task log appends, batched and written off Pi's thread.
//
// A chunk of task output joins its log file's pending text; one timer per
// window writes every file's pending text with one asynchronous append per
// file, and a file has at most one write in flight. A file whose pending text
// reaches LOG_WRITE_NOW_BYTES with no write in flight is written at once,
// without the window. A file whose pending text reaches LOG_MAX_PENDING_BYTES
// while a write is in flight holds its producer: append() returns a promise
// that resolves when the file's writes settle, and the task pauses its output
// until then.
//
// A write in flight past LOG_WRITE_STALL_MS stalls its file, and that one
// deadline frees every waiter: the producer's hold, flush() and drain(). Until
// the stalled write settles, text past the cap is counted and not kept, and a
// marker naming the count follows the text kept before it. A failed write's
// bytes are counted too, and a marker naming them and the error leads the next
// batch. A slow disk costs no output; a stalled or failing one costs counted
// bytes and never holds a task's output or its close.

import { appendFile } from "node:fs/promises";

import { createCoalescedCall, type CoalescedCallTimers } from "./coalesce.js";
import { logBackgroundDiagnostic } from "./diagnostics.js";

/** Window between a first pending chunk and its write. */
export const LOG_FLUSH_DELAY_MS = 250;

/** Pending bytes that start a file's write at once when none is in flight. */
export const LOG_WRITE_NOW_BYTES = 1024 * 1024;

/** Pending bytes at which a file holds its producer until the write in flight ends. */
export const LOG_MAX_PENDING_BYTES = 4 * 1024 * 1024;

/** How long a write may stay in flight before its file counts as stalled. */
export const LOG_WRITE_STALL_MS = 2_000;

export function failedLogMarker(bytes: number, error: string): string {
	return `\n[log dropped ${bytes} bytes: log write failed: ${error}]\n`;
}

export function stalledLogMarker(bytes: number): string {
	return `\n[log dropped ${bytes} bytes: log write stalled]\n`;
}

export interface LogWriter {
	/**
	 * Queue `text` for `file`. Returns null while the file can take more, or a
	 * promise that resolves once its writes settle or one stalls; the producer
	 * stops sending until then.
	 */
	append(file: string, text: string): Promise<void> | null;
	/**
	 * Write the file's pending text at once. Returns null when the file has no
	 * pending text and no write in flight, so it already holds every appended
	 * chunk; otherwise a promise that resolves once its writes settle or one
	 * stalls.
	 */
	flush(file: string): Promise<void> | null;
	/**
	 * Write the text pending at the call and resolve once those writes settle
	 * or stall. Text appended after the call waits for the next window.
	 */
	drain(): Promise<void>;
}

export interface LogWriterDeps extends CoalescedCallTimers {
	append?: (file: string, text: string) => Promise<void>;
	logDiagnostic?: (message: string, details: { file: string; error?: string; stallMs?: number }) => void;
}

interface FileQueue {
	pending: string[];
	pendingBytes: number;
	/** Bytes failed writes lost since the last batch was taken, and the last error. */
	failed: { bytes: number; error: string } | null;
	/** Bytes past the cap counted and not kept while the write in flight is stalled. */
	gapBytes: number;
	/** The file's write chain; `stalled` holds from the running write's deadline until it settles. */
	writing: { tail: Promise<void>; stalled: boolean } | null;
	/** Producers, flushes and drains waiting for the chain to settle or stall. */
	waiters: (() => void)[];
}

interface Batch {
	text: string;
	/** Task output bytes the batch accounts for, the counts in its markers included. */
	outputBytes: number;
}

export function createLogWriter(deps: LogWriterDeps = {}): LogWriter {
	const write = deps.append ?? ((file: string, text: string) => appendFile(file, text));
	const logDiagnostic = deps.logDiagnostic ?? logBackgroundDiagnostic;
	const setTimer = deps.setTimer ?? ((cb, ms) => setTimeout(cb, ms));
	const clearTimer = deps.clearTimer ?? ((handle) => clearTimeout(handle));
	const queues = new Map<string, FileQueue>();
	const flushWindow = createCoalescedCall(() => {
		for (const [file, queue] of queues) pump(file, queue);
	}, LOG_FLUSH_DELAY_MS, deps);

	function settledOrStalled(queue: FileQueue): Promise<void> {
		if (!queue.writing || queue.writing.stalled) return Promise.resolve();
		return new Promise<void>((resolve) => queue.waiters.push(resolve));
	}

	function takeBatch(queue: FileQueue): Batch | null {
		const { failed, gapBytes, pendingBytes } = queue;
		if (queue.pending.length === 0 && !failed) return null;
		const text = (failed ? failedLogMarker(failed.bytes, failed.error) : "")
			+ queue.pending.join("")
			+ (gapBytes > 0 ? stalledLogMarker(gapBytes) : "");
		queue.pending = [];
		queue.pendingBytes = 0;
		queue.failed = null;
		queue.gapBytes = 0;
		return { text, outputBytes: pendingBytes + gapBytes + (failed?.bytes ?? 0) };
	}

	async function writeBatch(file: string, queue: FileQueue, batch: Batch): Promise<void> {
		const stall = setTimer(() => {
			if (!queue.writing) throw new Error(`log_writer.stall_without_write file=${file}`);
			queue.writing.stalled = true;
			logDiagnostic("task log write stalled", { file, stallMs: LOG_WRITE_STALL_MS });
			for (const resolve of queue.waiters.splice(0)) resolve();
		}, LOG_WRITE_STALL_MS);
		(stall as { unref?: () => void }).unref?.();
		try {
			await write(file, batch.text);
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			queue.failed = { bytes: (queue.failed?.bytes ?? 0) + batch.outputBytes, error: message };
			logDiagnostic("task log append failed", { file, error: message });
		} finally {
			clearTimer(stall);
			if (queue.writing) queue.writing.stalled = false;
		}
	}

	// Chains after the queue's write in flight, so a file never has two.
	function startWrite(file: string, queue: FileQueue, batch: Batch): void {
		const tail: Promise<void> = (queue.writing?.tail ?? Promise.resolve())
			.then(() => writeBatch(file, queue, batch))
			.then(() => {
				if (queue.writing?.tail !== tail) return;
				queue.writing = null;
				for (const resolve of queue.waiters.splice(0)) resolve();
				// A failure marker alone waits for the file's next append or a
				// drain, so a disk that keeps failing is not retried on a timer.
				if (queue.pendingBytes >= LOG_WRITE_NOW_BYTES) pump(file, queue);
				else if (queue.pending.length > 0) flushWindow.request();
				else if (!queue.failed && queues.get(file) === queue) queues.delete(file);
			});
		queue.writing = { tail, stalled: false };
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

	// Takes the queue's batch, failure marker included, unless its write in
	// flight is stalled, and returns what a flush or drain waits for.
	function writeNow(file: string, queue: FileQueue): Promise<void> | null {
		if (!queue.writing?.stalled) {
			const batch = takeBatch(queue);
			if (batch) startWrite(file, queue, batch);
		}
		return queue.writing ? settledOrStalled(queue) : null;
	}

	return {
		append(file, text) {
			if (!text) return null;
			let queue = queues.get(file);
			if (!queue) {
				queue = { pending: [], pendingBytes: 0, failed: null, gapBytes: 0, writing: null, waiters: [] };
				queues.set(file, queue);
			}
			const bytes = Buffer.byteLength(text, "utf8");
			if (queue.writing?.stalled && queue.pendingBytes >= LOG_MAX_PENDING_BYTES) {
				queue.gapBytes += bytes;
				return null;
			}
			queue.pending.push(text);
			queue.pendingBytes += bytes;
			if (!queue.writing && queue.pendingBytes >= LOG_WRITE_NOW_BYTES) {
				pump(file, queue);
				return null;
			}
			flushWindow.request();
			if (queue.pendingBytes < LOG_MAX_PENDING_BYTES || queue.writing?.stalled) return null;
			return settledOrStalled(queue);
		},
		flush(file) {
			const queue = queues.get(file);
			return queue ? writeNow(file, queue) : null;
		},
		async drain() {
			flushWindow.cancel();
			await Promise.all([...queues].map(([file, queue]) => writeNow(file, queue)));
		},
	};
}

/** The log writer every task of this Pi process shares. */
export const taskLogs = createLogWriter();
