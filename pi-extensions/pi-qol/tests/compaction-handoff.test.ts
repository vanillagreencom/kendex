import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import {
	buildBudgetHandoff,
	collectArtifactRefs,
	findLatestTaskState,
	handoffBaseDir,
	piUserDir,
	safeFileName,
	sessionIdFromManager,
	writeBudgetHandoffArtifact,
} from "../extensions/qol/compaction-handoff.ts";

let workdir = "";
const originalAgentDir = process.env.PI_CODING_AGENT_DIR;

beforeEach(() => {
	workdir = mkdtempSync(join(tmpdir(), "pi-qol-handoff-"));
	process.env.PI_CODING_AGENT_DIR = workdir;
});

afterEach(() => {
	if (workdir) rmSync(workdir, { force: true, recursive: true });
	if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
});

test("piUserDir honors PI_CODING_AGENT_DIR", () => {
	expect(piUserDir()).toBe(workdir);
});

test("safeFileName sanitizes session ids into a single safe segment", () => {
	expect(safeFileName("good_id-123.tail")).toBe("good_id-123.tail");
	// Slashes get stripped so the result is one directory segment, not a path.
	const traversal = safeFileName("../etc/passwd");
	expect(traversal.includes("/")).toBe(false);
	expect(traversal.includes("\\")).toBe(false);
	expect(safeFileName("a b/c\\d:e?f*g")).toBe("a_b_c_d_e_f_g");
});

test("sessionIdFromManager prefers getSessionId then session file basename", () => {
	expect(sessionIdFromManager({ getSessionId: () => "s-id" })).toBe("s-id");
	expect(sessionIdFromManager({ getSessionId: () => undefined, getSessionFile: () => "/var/log/sessions/abc.jsonl" })).toBe("abc");
	expect(sessionIdFromManager({}, 9999)).toBe("ephemeral-9999");
});

test("sessionIdFromManager survives stale-ctx exceptions", () => {
	const sm = {
		getSessionId: () => {
			throw new Error("stale");
		},
		getSessionFile: () => {
			throw new Error("also stale");
		},
	};
	expect(sessionIdFromManager(sm, 1234)).toBe("ephemeral-1234");
});

test("findLatestTaskState pulls the latest tasks_write state", () => {
	const branch = [
		{ type: "message", message: { role: "toolResult", content: [{ type: "toolResult", details: { state: { tasks: ["a"] } } }] } },
		{ type: "message", message: { role: "assistant", content: [{ type: "text", text: "ok" }] } },
		{ type: "message", message: { role: "toolResult", content: [{ type: "toolResult", details: { state: { tasks: ["a", "b"] } } }] } },
	];
	expect(findLatestTaskState(branch)).toEqual({ tasks: ["a", "b"] });
});

test("findLatestTaskState returns undefined when no tool result state is present", () => {
	expect(findLatestTaskState([])).toBeUndefined();
	expect(findLatestTaskState([{ type: "message", message: { role: "assistant", content: [] } }])).toBeUndefined();
});

test("collectArtifactRefs harvests recent file-shaped paths from messages", () => {
	const branch = [
		{ type: "message", message: { role: "assistant", content: [{ type: "text", text: "Read src/main.rs and docs/notes.md" }] } },
		{ type: "message", message: { role: "assistant", content: [{ type: "text", text: "Also touched ./tmp/output.json" }] } },
	];
	const refs = collectArtifactRefs(branch);
	expect(refs).toContain("src/main.rs");
	expect(refs).toContain("docs/notes.md");
	expect(refs).toContain("./tmp/output.json");
});

test("collectArtifactRefs caps at maxRefs", () => {
	const branch = Array.from({ length: 50 }, (_, idx) => ({
		type: "message",
		message: { role: "assistant", content: [{ type: "text", text: `Wrote out-${idx}.md notes-${idx}.txt` }] },
	}));
	expect(collectArtifactRefs(branch, 5).length).toBe(5);
});

test("buildBudgetHandoff captures preparation + ctx state", () => {
	const branch = [
		{ type: "message", message: { role: "toolResult", content: [{ type: "toolResult", details: { state: { tasks: ["t"] } } }] } },
		{ type: "message", message: { role: "assistant", content: [{ type: "text", text: "ref docs/notes.md" }] } },
	];
	const sm = { getBranch: () => branch, getSessionId: () => "sess-42" };
	const handoff = buildBudgetHandoff({
		preparation: {
			messagesToSummarize: [{} as any, {} as any, {} as any],
			previousSummary: "prev-text",
			tokensBefore: 150_000,
			turnPrefixMessages: [{} as any],
		},
		reason: "test reason",
		sessionManager: sm,
		timestamp: 1_700_000_000_000,
	});
	expect(handoff.messageCount).toBe(4);
	expect(handoff.previousSummary).toBe("prev-text");
	expect(handoff.reason).toBe("test reason");
	expect(handoff.sessionId).toBe("sess-42");
	expect(handoff.taskState).toEqual({ tasks: ["t"] });
	expect(handoff.artifactRefs).toContain("docs/notes.md");
	expect(handoff.timestamp).toBe(1_700_000_000_000);
	expect(handoff.tokensBefore).toBe(150_000);
});

test("writeBudgetHandoffArtifact writes stamped + latest files when enabled", () => {
	const handoff = {
		artifactRefs: ["src/file.ts"],
		messageCount: 2,
		reason: "budget guard",
		sessionId: "sess-w1",
		timestamp: 1_700_000_000_000,
	};
	const result = writeBudgetHandoffArtifact(handoff, { enabled: true, root: workdir });
	expect(result.error).toBeUndefined();
	expect(result.path).toBeDefined();
	expect(result.latestPath).toBeDefined();
	expect(existsSync(result.path!)).toBe(true);
	expect(existsSync(result.latestPath!)).toBe(true);
	const stamped = JSON.parse(readFileSync(result.path!, "utf8"));
	expect(stamped.reason).toBe("budget guard");
	expect(stamped.sessionId).toBe("sess-w1");
	const latest = JSON.parse(readFileSync(result.latestPath!, "utf8"));
	expect(latest.reason).toBe("budget guard");
});

test("writeBudgetHandoffArtifact no-ops when disabled", () => {
	const handoff = {
		artifactRefs: [],
		messageCount: 0,
		reason: "test",
		sessionId: "s1",
		timestamp: Date.now(),
	};
	const result = writeBudgetHandoffArtifact(handoff, { enabled: false, root: workdir });
	expect(result).toEqual({});
});

test("writeBudgetHandoffArtifact surfaces fs errors instead of swallowing them", () => {
	const handoff = {
		artifactRefs: [],
		messageCount: 0,
		reason: "boom",
		sessionId: "s2",
		timestamp: Date.now(),
	};
	const result = writeBudgetHandoffArtifact(handoff, {
		enabled: true,
		mkdir: () => {
			throw new Error("permission denied");
		},
		root: workdir,
		writer: () => undefined,
	});
	expect(result.path).toBeUndefined();
	expect(result.error).toContain("permission denied");
});

test("writeBudgetHandoffArtifact sanitizes session ids in the on-disk path", () => {
	const handoff = {
		artifactRefs: [],
		messageCount: 0,
		reason: "sanitize",
		sessionId: "../etc/passwd",
		timestamp: 1_700_000_000_000,
	};
	const result = writeBudgetHandoffArtifact(handoff, { enabled: true, root: workdir });
	expect(result.path).toBeDefined();
	expect(result.path!.startsWith(handoffBaseDir(handoff.sessionId, workdir))).toBe(true);
	// The on-disk path must stay rooted under workdir, never escape via `..`.
	const absRoot = workdir.endsWith("/") ? workdir : `${workdir}/`;
	expect(result.path!.startsWith(absRoot)).toBe(true);
	expect(result.path).not.toContain("/etc/passwd");
	expect(dirname(result.path!)).toContain("passwd");
});
