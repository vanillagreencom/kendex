import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, sep } from "node:path";
import {
	buildBudgetHandoff, collectArtifactRefs, findLatestTaskState, handoffBaseDir,
	piUserDir, safeFileName, sessionIdFromManager, writeBudgetHandoffArtifact,
	type HandoffSessionAccessor,
} from "../extensions/qol/compaction-handoff.ts";

let workdir = "";
const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
const timestamp = 1_700_000_000_000;

beforeEach(() => {
	workdir = mkdtempSync(join(tmpdir(), "pi-qol-handoff-"));
	process.env.PI_CODING_AGENT_DIR = workdir;
});
afterEach(() => {
	try { if (workdir) rmSync(workdir, { force: true, recursive: true }); }
	finally {
		if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
	}
});

test("piUserDir honors PI_CODING_AGENT_DIR", () => {
	expect(piUserDir()).toBe(workdir);
});

const filenameCases = [
	{ name: "safe segment", input: "good_id-123.tail", expected: "good_id-123.tail" },
	{ name: "traversal separators", input: "../etc/passwd", expected: ".._etc_passwd" },
	{ name: "mixed separators", input: "a b/c\\d:e?f*g", expected: "a_b_c_d_e_f_g" },
];
if (filenameCases.length === 0) throw new Error("filename cases are empty");
for (const row of filenameCases) {
	test(`safeFileName: ${row.name}`, () => { expect(safeFileName(row.input)).toBe(row.expected); });
}

const sessionCases: { name: string; manager: HandoffSessionAccessor; pid: number; expected: string }[] = [
	{ name: "session id", manager: { getSessionId: () => "s-id" }, pid: 9999, expected: "s-id" },
	{ name: "file basename", manager: { getSessionId: () => undefined, getSessionFile: () => "/var/log/sessions/abc.jsonl" }, pid: 9999, expected: "abc" },
	{ name: "process fallback", manager: {}, pid: 9999, expected: "ephemeral-9999" },
	{ name: "stale accessors", manager: { getSessionId: () => { throw new Error("stale"); }, getSessionFile: () => { throw new Error("also stale"); } }, pid: 1234, expected: "ephemeral-1234" },
];
if (sessionCases.length === 0) throw new Error("session cases are empty");
for (const row of sessionCases) {
	test(`sessionIdFromManager: ${row.name}`, () => { expect(sessionIdFromManager(row.manager, row.pid)).toBe(row.expected); });
}

const taskCases = [
	{
		name: "latest tool result state",
		branch: [
			{ type: "message", message: { role: "toolResult", content: [{ type: "toolResult", details: { state: { tasks: ["a"] } } }] } },
			{ type: "message", message: { role: "assistant", content: [{ type: "text", text: "ok" }] } },
			{ type: "message", message: { role: "toolResult", content: [{ type: "toolResult", details: { state: { tasks: ["a", "b"] } } }] } },
		],
		expected: { tasks: ["a", "b"] },
	},
	{ name: "empty branch", branch: [], expected: undefined },
	{ name: "no tool result", branch: [{ type: "message", message: { role: "assistant", content: [] } }], expected: undefined },
];
if (taskCases.length === 0) throw new Error("task state cases are empty");
for (const row of taskCases) {
	test(`findLatestTaskState: ${row.name}`, () => { expect(findLatestTaskState(row.branch)).toEqual(row.expected); });
}

const referenceCases = [
	{
		name: "recent file paths",
		branch: [
			{ type: "message", message: { role: "assistant", content: [{ type: "text", text: "Read src/main.rs and docs/notes.md" }] } },
			{ type: "message", message: { role: "assistant", content: [{ type: "text", text: "Also touched ./tmp/output.json" }] } },
		],
		max: 20,
		expected: ["./tmp/output.json", "src/main.rs", "docs/notes.md"],
	},
	{
		name: "bounded recent paths",
		branch: Array.from({ length: 50 }, (_, index) => ({ type: "message", message: { role: "assistant", content: [{ type: "text", text: `Wrote out-${index}.md notes-${index}.txt` }] } })),
		max: 5,
		expected: ["out-49.md", "notes-49.txt", "out-48.md", "notes-48.txt", "out-47.md"],
	},
];
if (referenceCases.length === 0) throw new Error("reference cases are empty");
for (const row of referenceCases) {
	test(`collectArtifactRefs: ${row.name}`, () => { expect(collectArtifactRefs(row.branch, row.max)).toEqual(row.expected); });
}

test("buildBudgetHandoff captures preparation and session state", () => {
	const branch = [
		{ type: "message", message: { role: "toolResult", content: [{ type: "toolResult", details: { state: { tasks: ["t"] } } }] } },
		{ type: "message", message: { role: "assistant", content: [{ type: "text", text: "ref docs/notes.md" }] } },
	];
	expect(buildBudgetHandoff({
		preparation: { messagesToSummarize: [{}, {}, {}], previousSummary: "prev-text", tokensBefore: 150_000, turnPrefixMessages: [{}] },
		reason: "test reason", sessionManager: { getBranch: () => branch, getSessionId: () => "sess-42" }, timestamp,
	})).toEqual({
		artifactRefs: ["docs/notes.md"], messageCount: 4, previousSummary: "prev-text", reason: "test reason",
		sessionId: "sess-42", taskState: { tasks: ["t"] }, timestamp, tokensBefore: 150_000,
	});
});

const writerCases = [
	{
		name: "stamped and latest files",
		run: () => {
			const handoff = { artifactRefs: ["src/file.ts"], messageCount: 2, reason: "budget guard", sessionId: "sess-w1", timestamp };
			const result = writeBudgetHandoffArtifact(handoff, { enabled: true, root: workdir });
			return {
				errorAbsent: result.error === undefined, pathDefined: result.path !== undefined, latestDefined: result.latestPath !== undefined,
				stampedExists: typeof result.path === "string" && existsSync(result.path),
				latestExists: typeof result.latestPath === "string" && existsSync(result.latestPath),
				stamped: result.path && existsSync(result.path) ? JSON.parse(readFileSync(result.path, "utf8")) : undefined,
				latest: result.latestPath && existsSync(result.latestPath) ? JSON.parse(readFileSync(result.latestPath, "utf8")) : undefined,
			};
		},
		expected: {
			errorAbsent: true, pathDefined: true, latestDefined: true, stampedExists: true, latestExists: true,
			stamped: { artifactRefs: ["src/file.ts"], messageCount: 2, reason: "budget guard", sessionId: "sess-w1", timestamp },
			latest: { artifactRefs: ["src/file.ts"], messageCount: 2, reason: "budget guard", sessionId: "sess-w1", timestamp },
		},
	},
	{
		name: "disabled writer",
		run: () => writeBudgetHandoffArtifact({ artifactRefs: [], messageCount: 0, reason: "test", sessionId: "s1", timestamp }, { enabled: false, root: workdir }),
		expected: {},
	},
	{
		name: "filesystem error is forwarded",
		run: () => {
			const result = writeBudgetHandoffArtifact({ artifactRefs: [], messageCount: 0, reason: "boom", sessionId: "s2", timestamp }, {
				enabled: true, root: workdir, mkdir: () => { throw new Error("fixture-mkdir-error"); }, writer: () => undefined,
			});
			return { pathAbsent: result.path === undefined, error: result.error };
		},
		expected: { pathAbsent: true, error: "fixture-mkdir-error" },
	},
	{
		name: "session id remains inside the supplied root",
		run: () => {
			const result = writeBudgetHandoffArtifact({ artifactRefs: [], messageCount: 0, reason: "sanitize", sessionId: "../etc/passwd", timestamp }, { enabled: true, root: workdir });
			return {
				pathDefined: result.path !== undefined,
				handoffDirectory: result.path?.startsWith(handoffBaseDir("../etc/passwd", workdir)),
				rooted: result.path?.startsWith(workdir + sep), escaped: result.path?.includes("/etc/passwd"),
				sessionSegment: dirname(result.path!).includes("passwd"),
			};
		},
		expected: { pathDefined: true, handoffDirectory: true, rooted: true, escaped: false, sessionSegment: true },
	},
];
if (writerCases.length === 0) throw new Error("writer cases are empty");
for (const row of writerCases) {
	test(`writeBudgetHandoffArtifact: ${row.name}`, () => { expect(row.run()).toEqual(row.expected); });
}
