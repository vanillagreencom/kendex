import { AsyncLocalStorage } from "node:async_hooks";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { settingNumber } from "./settings.js";
import { MAX_CONCURRENCY } from "./types.js";

const cancellation = new AsyncLocalStorage<AbortSignal>();
const budgets = new WeakMap<ExtensionAPI, ChildBudget>();

/** Cancellation for command spawns nested inside a dispatch. */
export function childSignal(): AbortSignal | undefined {
	return cancellation.getStore();
}

type Waiter = { signal: AbortSignal; admit: () => void; reject: (error: unknown) => void; abort: () => void; cwd: string };
class ChildBudget {
	private active = 0;
	private readonly queued: Waiter[] = [];
	private readonly pending = new Set<Promise<unknown>>();
	readonly shutdown = new AbortController();

	run<T>(cwd: string, signal: AbortSignal, action: () => Promise<T>): Promise<T> {
		const work = this.runAction(cwd, signal, action);
		this.pending.add(work);
		void work.then(() => this.pending.delete(work), () => this.pending.delete(work));
		return work;
	}

	async close(): Promise<void> {
		this.shutdown.abort(new Error("Child dispatch session shut down"));
		await Promise.allSettled(this.pending);
	}

	private drain(): void {
		while (this.queued.length) {
			const next = this.queued[0];
			if (next.signal.aborted) {
				this.queued.shift();
				next.signal.removeEventListener("abort", next.abort);
				next.reject(next.signal.reason);
				continue;
			}
			const limit = Math.max(1, Math.floor(settingNumber("maxConcurrency", MAX_CONCURRENCY, next.cwd)));
			if (this.active >= limit) return;
			this.queued.shift();
			next.signal.removeEventListener("abort", next.abort);
			this.active++;
			next.admit();
		}
	}

	private async runAction<T>(cwd: string, signal: AbortSignal, action: () => Promise<T>): Promise<T> {
		signal.throwIfAborted();
		// Tool calls supply this queue; refuse excess work instead of retaining it indefinitely.
		if (this.queued.length >= 256) throw new Error("child-budget: pending limit=256");
		await new Promise<void>((admit, reject) => {
			const waiter: Waiter = { cwd, signal, admit, reject, abort: () => {
				const index = this.queued.indexOf(waiter);
				if (index !== -1) this.queued.splice(index, 1);
				reject(signal.reason);
				this.drain();
			} };
			this.queued.push(waiter);
			signal.addEventListener("abort", waiter.abort, { once: true });
			this.drain();
		});
		try {
			signal.throwIfAborted();
			return await cancellation.run(signal, action);
		} finally {
			this.active--;
			this.drain();
		}
	}
}

/** One runtime's dispatch modes share slots; pane work releases its slot after enqueue. */
export function withChildBudget<T>(pi: ExtensionAPI, cwd: string, signal: AbortSignal | undefined, action: () => Promise<T>): Promise<T> {
	let budget = budgets.get(pi);
	if (!budget) {
		budget = new ChildBudget();
		budgets.set(pi, budget);
		const owner = budget;
		const unsubscribe = pi.on("session_shutdown", async () => {
			await owner.close();
			budgets.delete(pi);
			unsubscribe();
		});
	}
	return budget.run(cwd, signal ? AbortSignal.any([signal, budget.shutdown.signal]) : budget.shutdown.signal, action);
}
