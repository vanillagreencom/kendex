import { mock } from "bun:test";
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { clearPackageConfigCache } from "../../package-config.js";
import type { DialogOptions } from "../../rpc-fallback.js";

const CONFIG_ID = "@vanillagreen/pi-questions";
const SERVICE = Symbol.for("kendex.pi-questions.service");
const MODAL_LOCK = Symbol.for("kendex.pi.modal-lock");

/** Dialog options of a request nothing settles and no timeout dismisses. */
export function unsettledDialogOptions(): DialogOptions {
	return { signal: new AbortController().signal };
}

/** The dependency-free test carrier implements only the Pi UI calls a case needs. */
export function mockQuestionRuntime(tui: Record<string, unknown> = {}): void {
	const unexpected = () => { throw new Error("Unexpected UI or output operation"); };
	mock.module("@earendil-works/pi-coding-agent", () => ({
		DEFAULT_MAX_BYTES: 1024,
		DEFAULT_MAX_LINES: 100,
		formatSize: String,
		truncateHead: unexpected,
		withFileMutationQueue: unexpected,
	}));
	mock.module("@earendil-works/pi-tui", () => ({
		Input: class { constructor() { unexpected(); } },
		matchesKey: unexpected,
		truncateToWidth: unexpected,
		visibleWidth: unexpected,
		wrapTextWithAnsi: unexpected,
		...tui,
	}));
}

/** The question service surface a test drives. */
export interface TestQuestionService {
	ask(ctx: unknown, payload: unknown, source?: string, signal?: AbortSignal): Promise<unknown>;
	listPending(): unknown[];
	reject(requestId: string, source?: string): boolean;
	subscribe(listener: (event: { action: string; source?: string }) => void): () => void;
}

/** The registered `question` tool. */
export interface TestQuestionTool {
	execute(toolCallId: string, params: unknown, signal: AbortSignal | undefined, onUpdate: undefined, ctx: unknown): Promise<unknown>;
}

export interface InstalledQuestionExtension {
	/** A fresh settings root; the user settings directory and the session cwd. */
	root: string;
	service: TestQuestionService;
	tool: TestQuestionTool;
	/** Shuts the session down and restores the service, settings directory and settings cache. */
	restore(): void;
}

/**
 * Runs the extension factory against a fresh service and a fresh user
 * settings directory holding `config` as the package's settings, so every
 * setting `config` does not name reads its declared default.
 */
export function installQuestionExtension(factory: (pi: never) => void, config: Record<string, unknown> = {}): InstalledQuestionExtension {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "question-service-")));
	const globals = globalThis as unknown as Record<PropertyKey, unknown>;
	const previousService = globals[SERVICE];
	const previousDir = process.env.PI_CODING_AGENT_DIR;
	const handlers = new Map<string, (...args: unknown[]) => unknown>();
	let tool: TestQuestionTool | undefined;
	process.env.PI_CODING_AGENT_DIR = root;
	writeFileSync(join(root, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { [CONFIG_ID]: config } } } }));
	clearPackageConfigCache();
	delete globals[SERVICE];
	const pi = {
		events: { emit() {} },
		on(name: string, handler: (...args: unknown[]) => unknown) { handlers.set(name, handler); },
		registerTool(definition: TestQuestionTool) { tool = definition; },
	};
	factory(pi as never);
	if (!tool) throw new Error("installQuestionExtension: the factory registered no question tool");
	return {
		root,
		service: globals[SERVICE] as TestQuestionService,
		tool,
		restore() {
			handlers.get("session_shutdown")?.();
			if (previousService === undefined) delete globals[SERVICE];
			else globals[SERVICE] = previousService;
			if (previousDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = previousDir;
			clearPackageConfigCache();
			rmSync(root, { force: true, recursive: true });
		},
	};
}

/**
 * Installs a fresh shared kendex modal lock at `depth`; a depth of 1 is another
 * package's popup holding it. `restore` puts the previous lock back.
 */
export function installModalLock(depth: number): { depth(): number; restore(): void } {
	const globals = globalThis as unknown as Record<PropertyKey, unknown>;
	const previous = globals[MODAL_LOCK];
	const lock = { depth };
	globals[MODAL_LOCK] = lock;
	return {
		depth: () => lock.depth,
		restore() {
			if (previous === undefined) delete globals[MODAL_LOCK];
			else globals[MODAL_LOCK] = previous;
		},
	};
}

/** Lets every queued promise continuation run; `await` never calls a patched `then`. */
export async function flushMicrotasks(): Promise<void> {
	for (let turn = 0; turn < 20; turn += 1) await null;
}
