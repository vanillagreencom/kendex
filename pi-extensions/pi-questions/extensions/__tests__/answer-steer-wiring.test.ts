import { describe, expect, mock, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { QuestionActivityEvent } from "../activity.js";
import { normalizeRequest } from "../question-model.js";

// These Pi dependencies are unavailable in a dependency-free package test.
// The test drives the registered service, without rendering a terminal UI.
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
}));

const { default: questions } = await import("../questions.js");
const SERVICE = Symbol.for("kendex.pi-questions.service");

interface Service {
	ask(ctx: unknown, payload: unknown): Promise<unknown>;
	reply(id: string, answers: string[][]): boolean;
	reject(id: string): boolean;
	subscribe(listener: (event: QuestionActivityEvent) => void): () => void;
}

describe("answer steer registration", () => {
	test("delivers answers only when enabled and keeps the original request on terminal events", async () => {
		for (const { setting, action, messages } of [
			{ setting: undefined, action: "answered", messages: [] },
			{ setting: false, action: "answered", messages: [] },
			{ setting: true, action: "answered", messages: [{ content: "> Which path?\n\nA", options: { deliverAs: "steer" } }] },
			{ setting: true, action: "rejected", messages: [] },
		] as const) {
			const root = mkdtempSync(join(tmpdir(), "question-steer-"));
			const previousDir = process.env.PI_CODING_AGENT_DIR;
			const globals = globalThis as unknown as Record<PropertyKey, unknown>;
			const previousService = globals[SERVICE];
			const handlers = new Map<string, (...args: unknown[]) => unknown>();
			try {
				process.env.PI_CODING_AGENT_DIR = root;
				delete globals[SERVICE];
				writeFileSync(join(root, "settings.json"), JSON.stringify({
					kendex: { extensionManager: { config: { "@vanillagreen/pi-questions": { answersAsUserMessage: setting } } } },
				}));
				const calls: Array<{ content: string; options: unknown }> = [];
				const pi = {
					events: { emit() {} },
					on(name: string, handler: (...args: unknown[]) => unknown) { handlers.set(name, handler); },
					registerTool() {},
					sendUserMessage(content: string, options: unknown) { calls.push({ content, options }); },
				};
				questions(pi as unknown as Parameters<typeof questions>[0]);
				const service = globals[SERVICE] as Service;
				const events: QuestionActivityEvent[] = [];
				service.subscribe((event) => events.push(event));
				const request = normalizeRequest({
					id: "que_wiring",
					questions: [{ header: "Path", question: "Which path?", options: [{ label: "A" }, { label: "B" }] }],
				});
				const pending = service.ask({ cwd: root, hasUI: false, ui: {} }, request);
				if (action === "answered") service.reply(request.id, [["A"]]);
				else service.reject(request.id);
				await pending;
				expect({ calls, events: events.map(({ action, request: original, requestId }) => ({ action, original, requestId })) }).toEqual({
					calls: messages,
					events: [
						{ action: "opened", original: request, requestId: request.id },
						{ action, original: request, requestId: request.id },
					],
				});
			} finally {
				handlers.get("session_shutdown")?.();
				if (previousService === undefined) delete globals[SERVICE];
				else globals[SERVICE] = previousService;
				if (previousDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
				else process.env.PI_CODING_AGENT_DIR = previousDir;
				rmSync(root, { recursive: true, force: true });
			}
		}
	});
});
