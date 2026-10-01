import { expect, spyOn } from "bun:test";
import * as fs from "node:fs";
import * as fsp from "node:fs/promises";
import { cpSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type { QolSessionSearchComponent } from "../extensions/qol/session-search/component.ts";
import type { QolSessionSearchSession, QolSessionSearchState } from "../extensions/qol/session-search/types.ts";

export const theme = { fg: (_color: string, text: string) => text, bg: (_color: string, text: string) => text };

export function scratch(): string { return realpathSync(mkdtempSync(join(tmpdir(), "qol-search-test-"))); }

export function session(root: string, index = 0): QolSessionSearchSession {
	return { allMessagesText: "", created: new Date(index), cwd: root, firstMessage: "alpha beta", id: `s${index}`, messageCount: 1, modified: new Date(index), path: join(root, `s${index}.jsonl`) };
}

/** Tests inspect state here instead of adding a readback API to Pi's component. */
export function componentState(component: QolSessionSearchComponent): { searchState: QolSessionSearchState; searchStatus?: { status: string; error?: string }; sessions: { status: string }; queryController?: AbortController } {
	return component as unknown as ReturnType<typeof componentState>;
}

/** A real event-loop wait is needed because index I/O and regex workers are
 * asynchronous. Timing tests measure completion, not the enqueue call. */
export async function settled(component: QolSessionSearchComponent): Promise<void> {
	const deadline = performance.now() + 3000;
	while (componentState(component).sessions.status === "loading" || componentState(component).searchStatus?.status === "searching") {
		if (performance.now() >= deadline) throw new Error("Component did not settle");
		await new Promise((resolve) => setTimeout(resolve, 1));
	}
	if (componentState(component).searchStatus?.status === "failed") throw new Error(componentState(component).searchStatus?.error);
}

export async function runtimeCopy<T>(relative: string, patches: Array<{ file: string; from: string; to: string; count?: number }>, use: (runtime: T, root: string) => Promise<void>): Promise<void> {
	const root = scratch();
	try {
		cpSync(resolve(import.meta.dir, "../extensions"), join(root, "extensions"), { recursive: true });
		cpSync(resolve(import.meta.dir, "../scripts"), join(root, "scripts"), { recursive: true });
		for (const patch of patches) {
			const path = join(root, "extensions", patch.file);
			const before = readFileSync(path, "utf8");
			expect(before.split(patch.from).length - 1).toBe(patch.count ?? 1);
			const after = before.replaceAll(patch.from, patch.to);
			expect(after).not.toBe(before);
			writeFileSync(path, after);
		}
		await use(await import(join(root, "extensions", relative)) as T, root);
	} finally { rmSync(root, { recursive: true, force: true }); }
}

export function imageReadSpies(beforeRead?: () => void, beforeOpen?: () => Promise<void>) {
	const originalOpen = fsp.open;
	const reads: ReturnType<typeof spyOn>[] = [];
	const closes: ReturnType<typeof spyOn>[] = [];
	const sync = spyOn(fs, "readFileSync");
	const opened = spyOn(fsp, "open").mockImplementation(async (...args: Parameters<typeof fsp.open>) => {
		await beforeOpen?.();
		const handle = await originalOpen(...args);
		const originalRead = handle.read.bind(handle);
		reads.push(spyOn(handle, "read").mockImplementation((...readArgs: unknown[]) => {
			beforeRead?.();
			return Reflect.apply(originalRead, handle, readArgs);
		}));
		closes.push(spyOn(handle, "close"));
		return handle;
	});
	return {
		count: () => reads.reduce((sum, read) => sum + read.mock.calls.length, 0) + sync.mock.calls.filter(([path]) => String(path).endsWith(".png")).length,
		closed: () => closes.every((close) => close.mock.calls.length === 1),
		restore: () => { opened.mockRestore(); sync.mockRestore(); reads.forEach((read) => read.mockRestore()); closes.forEach((close) => close.mockRestore()); },
	};
}

export function filesystemSpies() {
	const realpath = spyOn(fs.realpathSync, "native");
	const read = spyOn(fs, "readSync");
	const whole = spyOn(fs, "readFileSync");
	return {
		counts: () => ({ realpathSync: realpath.mock.calls.length, readSync: read.mock.calls.length, wholeLogReadFileSync: whole.mock.calls.filter(([path]) => String(path).endsWith(".jsonl")).length }),
		clear: () => { realpath.mockClear(); read.mockClear(); whole.mockClear(); },
		restore: () => { realpath.mockRestore(); read.mockRestore(); whole.mockRestore(); },
	};
}
