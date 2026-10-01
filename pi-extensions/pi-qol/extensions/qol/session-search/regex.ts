import { Worker } from "node:worker_threads";

export interface SessionRegexMatch { index: number; length: number }
type WorkerReply = { status: "ready" } | { status: "matched"; matches: Array<SessionRegexMatch | null> };

/** Run one query's matching in a disposable worker. User-entered regex can
 * backtrack forever, so the owner terminates it rather than timing exec. */
export function sessionRegexMatches(source: string, texts: string[], signal: AbortSignal): Promise<Array<SessionRegexMatch | null>> {
	signal.throwIfAborted();
	return new Promise((resolve, reject) => {
		const worker = new Worker(new URL("./regex-worker.mjs", import.meta.url), { execArgv: [], env: {} });
		let settled = false;
		// Startup is separate from the 25 ms execution budget.
		let timer = setTimeout(() => finish(new Error("SESSION_SEARCH_REGEX_DEADLINE: worker startup")), 1000);
		const finish = (error?: Error, matches?: Array<SessionRegexMatch | null>) => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			signal.removeEventListener("abort", abort);
			worker.removeAllListeners("message");
			// A runtime can defer thread exit until native regex execution returns.
			// Request cleanup without making input wait for that exit.
			worker.unref();
			void worker.terminate().catch((cleanupError: unknown) => {
				console.error("Session regex worker cleanup failed:", cleanupError);
			});
			if (error) reject(error);
			else resolve(matches!);
		};
		const abort = () => finish(new Error("Session search cancelled"));
		signal.addEventListener("abort", abort, { once: true });
		worker.on("message", (reply: WorkerReply) => {
			if (settled) return;
			switch (reply.status) {
				case "ready":
					clearTimeout(timer);
					timer = setTimeout(() => finish(new Error("SESSION_SEARCH_REGEX_DEADLINE: 25 ms")), 25);
					worker.postMessage({ source, texts });
					break;
				case "matched": finish(undefined, reply.matches); break;
				default: { const unexpected: never = reply; finish(new Error(`Unknown regex worker reply: ${unexpected}`)); }
			}
		});
		worker.once("error", (error) => finish(error));
		worker.once("exit", (code) => {
			if (!settled) finish(new Error(`Session regex worker exited before results: ${code}`));
		});
	});
}