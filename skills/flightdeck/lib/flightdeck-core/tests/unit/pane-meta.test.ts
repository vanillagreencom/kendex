// Unit tests for pane-meta helpers. tmux-dependent tests skip when no
// TMUX session is available.
import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";

import { PaneCache, resolvePaneId, sessionAlive, capturePane, captureHash12, stabilityForHarness, classifyBuffer } from "../../src/daemon/pane-meta.ts";

const INSIDE_TMUX = !!process.env.TMUX_PANE;

describe("captureHash12", () => {
	test("returns 12 hex chars", () => {
		expect(captureHash12("hello")).toMatch(/^[0-9a-f]{12}$/);
	});

	test("matches sha256 prefix domain", () => {
		// Cross-check with bash sha256sum | cut -c1-12 of the same input.
		const r = spawnSync("bash", ["-c", "printf '%s' \"$1\" | sha256sum | awk '{print substr($1,1,12)}'", "_", "abc"], { encoding: "utf8" });
		expect(r.status).toBe(0);
		expect(captureHash12("abc")).toBe((r.stdout ?? "").trim());
	});
});

describe("stabilityForHarness", () => {
	test("returns the default", () => {
		expect(stabilityForHarness("opencode", 3)).toBe(3);
		expect(stabilityForHarness("anything", 7)).toBe(7);
	});
});

describe("classifyBuffer built-in stub", () => {
	test("terminal-state-reached", () => {
		expect(classifyBuffer("MERGED, please end the session")).toBe("terminal-state-reached");
		expect(classifyBuffer("terminal state reached")).toBe("terminal-state-reached");
	});

	test("force-push-prompt", () => {
		expect(classifyBuffer("git push --force-with-lease?")).toBe("force-push-prompt");
	});

	test("merge-now", () => {
		expect(classifyBuffer("Ready to merge?")).toBe("merge-now");
		expect(classifyBuffer("merge now")).toBe("merge-now");
	});

	test("cleanup-prompt", () => {
		expect(classifyBuffer("delete worktree?")).toBe("cleanup-prompt");
		expect(classifyBuffer("keep worktree?")).toBe("cleanup-prompt");
	});

	test("rebase-multi-choice", () => {
		expect(classifyBuffer("rebase failed with conflict")).toBe("rebase-multi-choice");
		expect(classifyBuffer("how should we resolve conflict")).toBe("rebase-multi-choice");
	});

	test("generic-multi-choice", () => {
		expect(classifyBuffer("[1] yes [2] no")).toBe("generic-multi-choice");
		expect(classifyBuffer("(1) yes (2) no")).toBe("generic-multi-choice");
	});

	test("final GitHub pull URL requires no-footer adapter mode", () => {
		const text = "Done.\n\nhttps://github.com/vanillagreencom/vstack/pull/172";
		expect(classifyBuffer(text)).toBe("rendering");
		expect(classifyBuffer(text, { noFooterGate: true })).toBe("terminal-state-reached");
	});

	test("bash-permission-prompt", () => {
		expect(classifyBuffer("Allow this?")).toBe("bash-permission-prompt");
		expect(classifyBuffer("permission to run rm")).toBe("bash-permission-prompt");
		expect(classifyBuffer("approve this command")).toBe("bash-permission-prompt");
	});

	test("rendering fallback", () => {
		expect(classifyBuffer("hello world")).toBe("rendering");
	});
});

describe("PaneCache (live tmux)", () => {
	if (!INSIDE_TMUX) {
		test.skip("requires tmux", () => undefined);
		return;
	}
	test("refresh populates the current pane", () => {
		const cache = new PaneCache();
		cache.refresh();
		const myId = process.env.TMUX_PANE!;
		expect(cache.alive(myId)).toBe(true);
		expect(cache.target(myId)).toMatch(/^[^:]+:\d+\.\d+$/);
		expect(cache.windowId(myId)).toMatch(/^@\d+$/);
	});

	test("alive=false for unknown pane", () => {
		const cache = new PaneCache();
		cache.refresh();
		expect(cache.alive("%99999999")).toBe(false);
	});
});

describe("resolvePaneId + sessionAlive (live tmux)", () => {
	if (!INSIDE_TMUX) {
		test.skip("requires tmux", () => undefined);
		return;
	}
	test("resolves the current pane target", () => {
		const cache = new PaneCache();
		cache.refresh();
		const myId = process.env.TMUX_PANE!;
		const myTarget = cache.target(myId);
		expect(myTarget).toBeTruthy();
		expect(resolvePaneId(myTarget)).toBe(myId);
	});

	test("bogus target returns empty", () => {
		expect(resolvePaneId("no-such-session-XYZ:nope.0")).toBe("");
	});

	test("sessionAlive recognizes current session", () => {
		const r = spawnSync("tmux", ["display-message", "-p", "#{session_id}"], { encoding: "utf8" });
		const id = (r.stdout ?? "").trim();
		expect(sessionAlive(id)).toBe(true);
		expect(sessionAlive("$999999")).toBe(false);
	});
});

describe("capturePane (live tmux)", () => {
	if (!INSIDE_TMUX) {
		test.skip("requires tmux", () => undefined);
		return;
	}
	test("captures non-empty text from current pane", () => {
		const cache = new PaneCache();
		cache.refresh();
		const target = cache.target(process.env.TMUX_PANE!);
		const buf = capturePane(target, 50);
		expect(typeof buf).toBe("string");
	});
});
