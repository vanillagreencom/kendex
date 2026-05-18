import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

import { appendActivityEvent, tryAppendActivityEvent } from "../../src/activity/append.ts";
import { formatActivityJsonl, formatActivityLine, formatActivityMarkdown } from "../../src/activity/format.ts";
import { activityArchivePathFromStatePath, activityPathFromStatePath } from "../../src/activity/paths.ts";
import { ActivityFilterError, readActivityEvents, tailActivityEvents } from "../../src/activity/read.ts";
import { ActivityValidationError, activityEventId, normalizeActivityEvent } from "../../src/activity/types.ts";
import { archiveState } from "../../src/state/master-state.ts";

let dir = "";
function path(name: string): string { return join(dir, name); }

async function waitForPath(file: string): Promise<void> {
	const start = Date.now();
	while (!existsSync(file)) {
		if (Date.now() - start > 3000) throw new Error(`timed out waiting for ${file}`);
		await Bun.sleep(5);
	}
}

beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "fd-activity-")); });
afterEach(() => { if (dir && existsSync(dir)) rmSync(dir, { force: true, recursive: true }); });

describe("activity event normalization", () => {
	test("fills schema defaults and stable id from natural key", () => {
		const event = normalizeActivityEvent({
			source: "flightdeck",
			summary: "Registered worker",
			type: "entry.registered",
		}, { naturalKey: "entry:WORKER", sessionId: "S1", now: () => new Date("2026-05-15T00:00:00Z") });
		expect(event).toMatchObject({
			importance: "normal",
			schema_version: 1,
			session_id: "S1",
			severity: "info",
			ts: "2026-05-15T00:00:00.000Z",
		});
		expect(event.id).toBe(activityEventId({ naturalKey: "entry:WORKER", sessionId: "S1", type: "entry.registered" }));
	});

	test("computes ids from natural-key fallback rungs", () => {
		const base = { source: "flightdeck", summary: "fallback", type: "entry.state_changed" };
		const opts = { sessionId: "S1", now: () => new Date("2026-05-15T00:00:00Z") };
		expect(normalizeActivityEvent({ ...base, details: { dedup_key: "dedup" } }, opts).id)
			.toBe(activityEventId({ naturalKey: "dedup", sessionId: "S1", type: "entry.state_changed" }));
		expect(normalizeActivityEvent({ ...base, refs: { task_id: "task-1" } }, opts).id)
			.toBe(activityEventId({ naturalKey: "task-1", sessionId: "S1", type: "entry.state_changed" }));
		expect(normalizeActivityEvent({ ...base, refs: { bg_task_id: "bg-1" } }, opts).id)
			.toBe(activityEventId({ naturalKey: "bg-1", sessionId: "S1", type: "entry.state_changed" }));
		expect(normalizeActivityEvent({ ...base, refs: { question_id: "q-1" } }, opts).id)
			.toBe(activityEventId({ naturalKey: "q-1", sessionId: "S1", type: "entry.state_changed" }));
		expect(normalizeActivityEvent({ ...base, refs: { commit: "abc123" } }, opts).id)
			.toBe(activityEventId({ naturalKey: "abc123", sessionId: "S1", type: "entry.state_changed" }));
		expect(normalizeActivityEvent(base, opts).id)
			.toBe(activityEventId({ naturalKey: "2026-05-15T00:00:00.000Z", sessionId: "S1", type: "entry.state_changed" }));
	});

	test("explicit id wins over natural-key fallback", () => {
		const event = normalizeActivityEvent({
			details: { dedup_key: "dedup" },
			id: "explicit-id",
			source: "flightdeck",
			summary: "explicit",
			type: "entry.state_changed",
		}, { sessionId: "S1", now: () => new Date("2026-05-15T00:00:00Z") });
		expect(event.id).toBe("explicit-id");
	});

	test("invalid severity and importance are validation errors", () => {
		expect(() => normalizeActivityEvent({ severity: "bad", source: "flightdeck", summary: "bad", type: "entry.state_changed" }))
			.toThrow(ActivityValidationError);
		expect(() => normalizeActivityEvent({ importance: "bad", source: "flightdeck", summary: "bad", type: "entry.state_changed" }))
			.toThrow(ActivityValidationError);
	});

	test("normalizes refs.branch (vstack#101) and skips empty values", () => {
		const withBranch = normalizeActivityEvent({
			refs: { branch: "feature/spike", pr_number: 88 },
			source: "github",
			summary: "PR with branch",
			type: "pr.merged",
		}, { naturalKey: "pr:88:merged", sessionId: "S1" });
		expect(withBranch.refs?.branch).toBe("feature/spike");
		expect(withBranch.refs?.pr_number).toBe(88);

		const emptyBranch = normalizeActivityEvent({
			refs: { branch: "", pr_number: 88 },
			source: "github",
			summary: "PR no branch",
			type: "pr.merged",
		}, { naturalKey: "pr:88:merged:nobranch", sessionId: "S1" });
		expect(emptyBranch.refs?.branch).toBeUndefined();
	});

	test("accepts new agent.rate_limit_* types (vstack#108)", () => {
		for (const type of [
			"agent.rate_limited",
			"agent.rate_limit_retry",
			"agent.rate_limit_skipped",
			"agent.rate_limit_resolved",
			"agent.rate_limit_exhausted",
		]) {
			const event = normalizeActivityEvent(
				{
					details: { attempt: 2, next_retry_at: 1_700_000_000_000 },
					refs: { agent: "rust" },
					source: "pi-agents-tmux",
					summary: `rust ${type}`,
					type,
				},
				{ naturalKey: `pane:%41:${type}`, sessionId: "S1" },
			);
			expect(event.type).toBe(type);
			expect(event.refs?.agent).toBe("rust");
			expect(event.details?.attempt).toBe(2);
		}
	});

	test("accepts new pr/issue labeled and unlabeled types", () => {
		for (const type of ["pr.labeled", "pr.unlabeled", "issue.labeled", "issue.unlabeled"]) {
			const event = normalizeActivityEvent(
				{
					details: { label: "defer-ci", reason: "skip heavy CI" },
					refs: { pr_number: 44 },
					source: "github",
					summary: `Added defer-ci via ${type}`,
					type,
				},
				{ naturalKey: `pr:44:${type}`, sessionId: "S1" },
			);
			expect(event.type).toBe(type);
			expect(event.severity).toBe("info");
			expect(event.importance).toBe("normal");
			expect(event.refs?.pr_number).toBe(44);
			expect(event.details?.label).toBe("defer-ci");
			expect(event.details?.reason).toBe("skip heavy CI");
		}
	});

	test("normalizes refs, links, noisy flag, and caps oversized details", () => {
		const event = normalizeActivityEvent({
			details: { huge: "x".repeat(128) },
			importance: "noisy",
			links: [{ label: "state", path: "tmp/state.json" }],
			refs: { pr_number: 12, issue_id: "FD-12" },
			severity: "success",
			source: "workflow",
			summary: "Decision recorded",
			type: "decision.recorded",
		}, { detailsMaxBytes: 32, naturalKey: "decision:1", now: () => new Date("2026-05-15T00:00:00Z") });
		expect(event.noisy).toBe(true);
		expect(event.links).toEqual([{ label: "state", path: "tmp/state.json" }]);
		expect(event.refs).toEqual({ issue_id: "FD-12", pr_number: 12 });
		expect(event.details).toEqual({ original_bytes: 139, truncated: true });
	});
});

describe("activity append/read", () => {
	test("nonblocking append returns lock-busy instead of waiting forever", async () => {
		const file = path("activity-busy.jsonl");
		const readyFile = path("activity-busy-ready");
		const holder = Bun.spawn([
			"bash", "-c",
			"lock=\"$1\"; ready=\"$2\"; flock -x \"$lock\" bash -c 'printf ready > \"$1\"; sleep 2' _ \"$ready\"",
			"_", `${file}.lock`, readyFile,
		], { stderr: "pipe", stdout: "pipe" });
		await waitForPath(readyFile);
		const started = Date.now();
		const result = tryAppendActivityEvent(file, {
			entry_id: "BUSY",
			natural_key: "busy",
			source: "daemon",
			summary: "busy append",
			type: "daemon.warning",
		}, { sessionId: "S1" });
		expect(result).toMatchObject({ appended: false, reason: "lock-busy" });
		expect(Date.now() - started).toBeLessThan(1800);
		expect(await holder.exited).toBe(0);
	});

	test("append writes JSONL and dedupes duplicate ids", () => {
		const file = path("activity.jsonl");
		const first = appendActivityEvent(file, {
			entry_id: "A1",
			natural_key: "A1:registered",
			source: "flightdeck",
			summary: "A1 registered",
			type: "entry.registered",
		}, { sessionId: "S1", now: () => new Date("2026-05-15T00:00:00Z") });
		const second = appendActivityEvent(file, {
			entry_id: "A1",
			natural_key: "A1:registered",
			source: "flightdeck",
			summary: "A1 registered",
			type: "entry.registered",
		}, { sessionId: "S1", now: () => new Date("2026-05-15T00:00:01Z") });
		expect(first.appended).toBe(true);
		expect(second.appended).toBe(false);
		expect(readFileSync(file, "utf8").trim().split("\n")).toHaveLength(1);
		expect(readActivityEvents(file)).toEqual([first.event]);
	});

	test("append trims from the head until event and byte caps both pass", () => {
		const file = path("retained/activity.jsonl");
		for (let i = 0; i < 16; i += 1) {
			appendActivityEvent(file, {
				body: "x".repeat(120 + i * 10),
				natural_key: `event:${i}`,
				source: "flightdeck",
				summary: `event ${i}`,
				type: "entry.state_changed",
			}, { maxBytes: 1600, maxEvents: 100, sessionId: "S1", now: () => new Date(`2026-05-15T00:00:${String(i).padStart(2, "0")}Z`) });
		}
		const raw = readFileSync(file, "utf8");
		expect(Buffer.byteLength(raw, "utf8")).toBeLessThanOrEqual(1600);
		const events = raw.trim().split("\n").map((line) => JSON.parse(line) as { summary: string });
		expect(events.at(-1)?.summary).toBe("event 15");
		expect(events.map((event) => event.summary)).not.toContain("event 0");
	});

	test("reader skips invalid lines, dedupes, filters, and tails", () => {
		const file = path("activity.jsonl");
		const one = normalizeActivityEvent({ source: "daemon", summary: "daemon started", type: "daemon.started" }, { naturalKey: "daemon", now: () => new Date("2026-05-15T00:00:00Z") });
		const two = normalizeActivityEvent({ entry_id: "E1", severity: "warning", source: "daemon", summary: "subscriber died", type: "subscriber.dead" }, { naturalKey: "sub", now: () => new Date("2026-05-15T00:00:01Z") });
		writeFileSync(file, `${JSON.stringify(one)}\nnot-json\n${JSON.stringify(one)}\n${JSON.stringify(two)}\n`, "utf8");
		const warnings: string[] = [];
		expect(readActivityEvents(file, { warn: (msg) => warnings.push(msg) })).toEqual([one, two]);
		expect(warnings[0]).toContain("invalid activity JSONL");
		expect(readActivityEvents(file, { filter: "severity=warning" })).toEqual([two]);
		expect(readActivityEvents(file, { filter: "severity!=info,entry=E1" })).toEqual([two]);
		expect(() => readActivityEvents(file, { filter: "unknown=value" })).toThrow(ActivityFilterError);
		expect(() => readActivityEvents(file, { filter: "severity:warning" })).toThrow(ActivityFilterError);
		expect(tailActivityEvents(file, 1)).toEqual([two]);
	});

	test("formatters produce JSONL, markdown, and one-line output", () => {
		const event = normalizeActivityEvent({ entry_id: "E1", source: "workflow", summary: "Prompt answered", type: "question.answered" }, { naturalKey: "q1", now: () => new Date("2026-05-15T00:00:00Z") });
		expect(formatActivityLine(event)).toContain("question.answered entry=E1");
		expect(formatActivityJsonl([event])).toBe(`${JSON.stringify(event)}\n`);
		expect(formatActivityMarkdown([event])).toContain("`question.answered`");
	});

	test("concurrent appenders serialize distinct events under the activity lock", async () => {
		const file = path("concurrent/activity.jsonl");
		const appendModule = pathToFileURL(resolve(dirname(import.meta.path), "../../src/activity/append.ts")).href;
		const script = `import { appendActivityEvent } from ${JSON.stringify(appendModule)};\nconst writer = process.env.WRITER;\nfor (let i = 0; i < 100; i += 1) {\n\tappendActivityEvent(process.env.ACTIVITY_FILE, {source:"flightdeck", type:"entry.registered", summary:"writer " + writer + " event " + i, entry_id:"E" + writer, natural_key:writer + ":" + i}, {sessionId:"S1", now:()=>new Date("2026-05-15T00:00:00Z")});\n}`;
		const procs = Array.from({ length: 8 }, (_, writer) => Bun.spawn(["bun", "--eval", script], {
			env: { ...(process.env as Record<string, string>), ACTIVITY_FILE: file, WRITER: String(writer) },
			stderr: "pipe",
			stdout: "pipe",
		}));
		const statuses = await Promise.all(procs.map((proc) => proc.exited));
		expect(statuses.every((status) => status === 0)).toBe(true);
		const lines = readFileSync(file, "utf8").trim().split("\n");
		expect(lines).toHaveLength(800);
		const ids = new Set<string>();
		for (const line of lines) {
			const parsed = JSON.parse(line) as { id: string };
			expect(ids.has(parsed.id)).toBe(false);
			ids.add(parsed.id);
		}
		expect(ids.size).toBe(800);
	});
});

describe("activity archive", () => {
	function writeState(stateFile: string, terminatedAt: string): void {
		writeFileSync(stateFile, JSON.stringify({
			activity_path: activityPathFromStatePath(stateFile),
			activity_schema_version: 1,
			entries: {},
			terminated_at: terminatedAt,
		}), "utf8");
	}

	function appendSeed(activityFile: string, summary = "seed"): void {
		appendActivityEvent(activityFile, {
			natural_key: summary,
			source: "flightdeck",
			summary,
			type: "session.started",
		}, { sessionId: "SENTINEL", now: () => new Date("2026-05-15T00:00:00Z") });
	}

	function archiveScript(): string {
		const stateModule = pathToFileURL(resolve(dirname(import.meta.path), "../../src/state/master-state.ts")).href;
		return `import { archiveState } from ${JSON.stringify(stateModule)};\nconst archive = archiveState(process.env.STATE_FILE);\nif (archive) process.stdout.write(archive + "\\n");`;
	}

	async function waitForFile(file: string): Promise<void> {
		const start = Date.now();
		while (!existsSync(file)) {
			if (Date.now() - start > 3000) throw new Error(`timed out waiting for ${file}`);
			await Bun.sleep(5);
		}
	}

	test("archive skips missing activity sidecar and clears activity pointers", () => {
		const stateFile = path("flightdeck-state-MISSING.json");
		const terminatedAt = "2026-05-15T00:01:00Z";
		writeState(stateFile, terminatedAt);
		const archive = archiveState(stateFile);
		expect(archive).not.toBeNull();
		const archived = JSON.parse(readFileSync(archive!, "utf8")) as { activity_archive_path?: unknown; activity_path?: unknown };
		expect(archived.activity_path).toBeUndefined();
		expect(archived.activity_archive_path).toBeUndefined();
		expect(existsSync(activityArchivePathFromStatePath(stateFile, terminatedAt))).toBe(false);
	});

	test("archive skips zero-byte activity sidecar and leaves no archive", () => {
		const stateFile = path("flightdeck-state-EMPTY.json");
		const terminatedAt = "2026-05-15T00:02:00Z";
		writeState(stateFile, terminatedAt);
		const activityFile = activityPathFromStatePath(stateFile);
		writeFileSync(activityFile, "", "utf8");
		const archive = archiveState(stateFile);
		expect(archive).not.toBeNull();
		const archived = JSON.parse(readFileSync(archive!, "utf8")) as { activity_archive_path?: unknown; activity_path?: unknown };
		expect(archived.activity_path).toBeUndefined();
		expect(archived.activity_archive_path).toBeUndefined();
		expect(existsSync(activityArchivePathFromStatePath(stateFile, terminatedAt))).toBe(false);
		expect(existsSync(activityFile)).toBe(true);
	});

	test("archive waits for an in-flight append and moves the completed line", async () => {
		const stateFile = path("flightdeck-state-RACE.json");
		const terminatedAt = "2026-05-15T00:03:00Z";
		writeState(stateFile, terminatedAt);
		const activityFile = activityPathFromStatePath(stateFile);
		const readyFile = path("activity-lock-ready");
		const appendModule = pathToFileURL(resolve(dirname(import.meta.path), "../../src/activity/append.ts")).href;
		const holder = Bun.spawn([
			"bash", "-c",
			"lock=\"$1\"; ready=\"$2\"; flock -x \"$lock\" bash -c 'printf ready > \"$1\"; sleep 0.5' _ \"$ready\"",
			"_", `${activityFile}.lock`, readyFile,
		], { stderr: "pipe", stdout: "pipe" });
		while (!existsSync(readyFile)) await Bun.sleep(5);
		const script = `import { appendActivityEvent } from ${JSON.stringify(appendModule)};\nappendActivityEvent(process.env.ACTIVITY_FILE, {source:"flightdeck", type:"entry.registered", summary:"race append", entry_id:"R1", natural_key:"race"}, {sessionId:"RACE", now:()=>new Date("2026-05-15T00:03:00Z")});`;
		const append = Bun.spawn(["bun", "--eval", script], { env: { ...(process.env as Record<string, string>), ACTIVITY_FILE: activityFile }, stderr: "pipe", stdout: "pipe" });
		await Bun.sleep(100);
		const archive = archiveState(stateFile);
		expect(await holder.exited).toBe(0);
		expect(await append.exited).toBe(0);
		expect(archive).not.toBeNull();
		const activityArchive = activityArchivePathFromStatePath(stateFile, terminatedAt);
		expect(existsSync(activityArchive)).toBe(true);
		const archivedLines = readFileSync(activityArchive, "utf8").trim().split("\n");
		expect(archivedLines).toHaveLength(1);
		expect(JSON.parse(archivedLines[0]!) as { summary: string }).toMatchObject({ summary: "race append" });
		expect(existsSync(activityFile)).toBe(false);
	});

	test("append racing an archive sees the sentinel and does not recreate the live file", async () => {
		const stateFile = path("flightdeck-state-SENTINEL.json");
		const terminatedAt = "2026-05-15T00:04:00Z";
		writeState(stateFile, terminatedAt);
		const activityFile = activityPathFromStatePath(stateFile);
		appendSeed(activityFile, "seed before race");
		const wrapperDir = path("stub-bin");
		mkdirSync(wrapperDir, { recursive: true });
		const readyFile = path("archive-mv-ready");
		const mvWrapper = join(wrapperDir, "mv");
		writeFileSync(mvWrapper, `#!/usr/bin/env bash\nif [[ "$1" == "$ACTIVITY_FILE" ]]; then\n  : > "$ARCHIVE_READY_FILE"\n  sleep 0.3\nfi\nexec /usr/bin/mv "$@"\n`, "utf8");
		chmodSync(mvWrapper, 0o755);
		const archive = Bun.spawn(["bun", "--eval", archiveScript()], {
			env: {
				...(process.env as Record<string, string>),
				ACTIVITY_FILE: activityFile,
				ARCHIVE_READY_FILE: readyFile,
				PATH: `${wrapperDir}:${process.env.PATH ?? ""}`,
				STATE_FILE: stateFile,
			},
			stderr: "pipe",
			stdout: "pipe",
		});
		await waitForFile(readyFile);
		const append = appendActivityEvent(activityFile, {
			natural_key: "after-archive-race",
			source: "flightdeck",
			summary: "after archive race",
			type: "entry.registered",
		}, { sessionId: "SENTINEL", now: () => new Date("2026-05-15T00:04:01Z") });
		expect(await archive.exited).toBe(0);
		expect(append).toMatchObject({ appended: false, archived: true });
		const activityArchive = activityArchivePathFromStatePath(stateFile, terminatedAt);
		expect(existsSync(activityArchive)).toBe(true);
		expect(existsSync(activityFile)).toBe(false);
		expect(existsSync(`${activityFile}.archived`)).toBe(true);
		const archivedLines = readFileSync(activityArchive, "utf8").trim().split("\n");
		expect(archivedLines).toHaveLength(1);
		expect(readFileSync(activityArchive, "utf8")).toContain("seed before race");
		expect(readFileSync(activityArchive, "utf8")).not.toContain("after archive race");
	});

	test("append queued after archive no-ops when sentinel exists", async () => {
		const stateFile = path("flightdeck-state-QUEUED.json");
		const terminatedAt = "2026-05-15T00:05:00Z";
		writeState(stateFile, terminatedAt);
		const activityFile = activityPathFromStatePath(stateFile);
		appendSeed(activityFile, "seed before queued");
		const readyFile = path("manual-lock-ready");
		const releaseFile = path("manual-lock-release");
		const holder = Bun.spawn([
			"bash", "-c",
			"lock=\"$1\"; ready=\"$2\"; release=\"$3\"; flock -x \"$lock\" bash -c 'printf ready > \"$1\"; while [[ ! -e \"$2\" ]]; do sleep 0.01; done' _ \"$ready\" \"$release\"",
			"_", `${activityFile}.lock`, readyFile, releaseFile,
		], { stderr: "pipe", stdout: "pipe" });
		await waitForFile(readyFile);
		const archive = Bun.spawn(["bun", "--eval", archiveScript()], {
			env: { ...(process.env as Record<string, string>), STATE_FILE: stateFile },
			stderr: "pipe",
			stdout: "pipe",
		});
		await Bun.sleep(100);
		writeFileSync(releaseFile, "go", "utf8");
		expect(await holder.exited).toBe(0);
		expect(await archive.exited).toBe(0);
		const append = appendActivityEvent(activityFile, {
			natural_key: "after-queued-archive",
			source: "flightdeck",
			summary: "after queued archive",
			type: "entry.registered",
		}, { sessionId: "SENTINEL", now: () => new Date("2026-05-15T00:05:01Z") });
		expect(append).toMatchObject({ appended: false, archived: true });
		const activityArchive = activityArchivePathFromStatePath(stateFile, terminatedAt);
		expect(existsSync(activityArchive)).toBe(true);
		expect(existsSync(activityFile)).toBe(false);
		expect(existsSync(`${activityFile}.archived`)).toBe(true);
		const archived = readFileSync(activityArchive, "utf8");
		expect(archived).toContain("seed before queued");
		expect(archived).not.toContain("after queued archive");
	});
});
