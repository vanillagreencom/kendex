// Regression coverage for vstack#57: adhoc Pi panes that reach
// `isIdle: true && hasPendingMessages: false` must classify as
// `terminal-state-reached`, NOT `idle`, so session-watch advances
// waiting -> complete. Issue-mode and non-pi adhoc entries keep their
// existing classifier behavior.

import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { classifyPiBridgeState } from "../../src/classifier/pi-bridge-state.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const PROMPT_CLASSIFY = resolve(HERE, "../../src/bin/prompt-classify.ts");

function tmpStateFile(contents: unknown): string {
	const dir = mkdtempSync(join(tmpdir(), "fd-bridge-state-"));
	const file = join(dir, "state.json");
	writeFileSync(file, typeof contents === "string" ? contents : JSON.stringify(contents), { encoding: "utf8" });
	return file;
}

function runClassifyBridge(stateFile: string, opts: { entryKind?: string; entryHarness?: string; dryRun?: boolean } = {}): { stdout: string; stderr: string; status: number | null } {
	const args = ["run", PROMPT_CLASSIFY, "--bridge-state-file", stateFile];
	if (opts.entryKind !== undefined) args.push("--entry-kind", opts.entryKind);
	if (opts.entryHarness !== undefined) args.push("--entry-harness", opts.entryHarness);
	if (opts.dryRun) args.push("--dry-run");
	const r = spawnSync("bun", args, { encoding: "utf8" });
	return { stdout: (r.stdout ?? "").trim(), stderr: r.stderr ?? "", status: r.status };
}

describe("classifyPiBridgeState (vstack#57)", () => {
	test("adhoc pi idle with no pending messages -> terminal-state-reached", () => {
		const result = classifyPiBridgeState({ isIdle: true, hasPendingMessages: false }, { entryKind: "adhoc", entryHarness: "pi" });
		expect(result.tag).toBe("terminal-state-reached");
		expect(result.matched).toContain("adhoc pi idle");
	});

	test("wrapped pi-bridge state under data -> terminal-state-reached", () => {
		const result = classifyPiBridgeState({ data: { isIdle: true, hasPendingMessages: false } }, { entryKind: "workflow", entryHarness: "pi" });
		expect(result.tag).toBe("terminal-state-reached");
		expect(result.matched).toContain("workflow pi idle");
	});

	test("issue-kind pi idle with no pending messages -> idle (unchanged)", () => {
		const result = classifyPiBridgeState({ isIdle: true, hasPendingMessages: false }, { entryKind: "issue", entryHarness: "pi" });
		expect(result.tag).toBe("idle");
	});

	test("adhoc claude idle with no pending messages -> idle (gated on harness=pi)", () => {
		const result = classifyPiBridgeState({ isIdle: true, hasPendingMessages: false }, { entryKind: "adhoc", entryHarness: "claude" });
		expect(result.tag).toBe("idle");
	});

	test("adhoc pi idle WITH pending messages -> idle (waiting on inbox)", () => {
		const result = classifyPiBridgeState({ isIdle: true, hasPendingMessages: true }, { entryKind: "adhoc", entryHarness: "pi" });
		expect(result.tag).toBe("idle");
	});

	test("adhoc pi busy (not idle) -> rendering", () => {
		const result = classifyPiBridgeState({ isIdle: false, hasPendingMessages: false }, { entryKind: "adhoc", entryHarness: "pi" });
		expect(result.tag).toBe("rendering");
	});

	test("unknown kind/harness with idle no-pending -> idle (does NOT default to terminal)", () => {
		const result = classifyPiBridgeState({ isIdle: true, hasPendingMessages: false }, { entryKind: "", entryHarness: "" });
		expect(result.tag).toBe("idle");
	});

	test("missing/malformed bridge state -> rendering (defensive default)", () => {
		expect(classifyPiBridgeState(null, { entryKind: "adhoc", entryHarness: "pi" }).tag).toBe("rendering");
		expect(classifyPiBridgeState(undefined, { entryKind: "adhoc", entryHarness: "pi" }).tag).toBe("rendering");
		expect(classifyPiBridgeState({}, { entryKind: "adhoc", entryHarness: "pi" }).tag).toBe("rendering");
	});

	test("case-insensitive kind/harness matching", () => {
		const result = classifyPiBridgeState({ isIdle: true, hasPendingMessages: false }, { entryKind: "ADHOC", entryHarness: "Pi" });
		expect(result.tag).toBe("terminal-state-reached");
	});
});

describe("prompt-classify --bridge-state-file (vstack#57)", () => {
	test("CLI returns terminal-state-reached for adhoc pi idle no-pending", () => {
		const file = tmpStateFile({ isIdle: true, hasPendingMessages: false });
		const r = runClassifyBridge(file, { entryKind: "adhoc", entryHarness: "pi" });
		expect(r.status).toBe(0);
		expect(r.stdout).toBe("terminal-state-reached");
	});

	test("CLI returns terminal-state-reached for wrapped workflow pi idle no-pending", () => {
		const file = tmpStateFile({ data: { isIdle: true, hasPendingMessages: false } });
		const r = runClassifyBridge(file, { entryKind: "workflow", entryHarness: "pi", dryRun: true });
		expect(r.status).toBe(0);
		expect(r.stdout).toMatch(/^terminal-state-reached	workflow pi idle/);
	});

	test("CLI returns idle for issue-kind pi idle no-pending", () => {
		const file = tmpStateFile({ isIdle: true, hasPendingMessages: false });
		const r = runClassifyBridge(file, { entryKind: "issue", entryHarness: "pi" });
		expect(r.status).toBe(0);
		expect(r.stdout).toBe("idle");
	});

	test("CLI --dry-run prints matched annotation", () => {
		const file = tmpStateFile({ isIdle: true, hasPendingMessages: false });
		const r = runClassifyBridge(file, { entryKind: "adhoc", entryHarness: "pi", dryRun: true });
		expect(r.status).toBe(0);
		expect(r.stdout).toMatch(/^terminal-state-reached\tadhoc pi idle/);
	});

	test("CLI gracefully degrades on malformed JSON", () => {
		const file = tmpStateFile("not json");
		const r = runClassifyBridge(file, { entryKind: "adhoc", entryHarness: "pi" });
		expect(r.status).toBe(0);
		expect(r.stdout).toBe("rendering");
	});
});
