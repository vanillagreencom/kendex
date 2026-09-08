import { afterAll, mock } from "bun:test";
import * as childProcess from "node:child_process";
import { mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Leak guard: every tempdir this suite creates must be torn down by the test
// file that created it. The whole run gets its OWN tmp root (os.tmpdir()
// re-reads TMPDIR per call, and this preload runs before any test module),
// so concurrent pi-agents-tmux runs can never flag each other's live dirs,
// unrelated system churn is invisible, and the final sweep removes the root
// wholesale after reporting. A short settle pass absorbs writes that land
// during shutdown so a just-recreated dir is measured at rest.
const RUN_TMP_ROOT = mkdtempSync(join(tmpdir(), "pi-agents-tmux-run-"));
process.env.TMPDIR = RUN_TMP_ROOT;

afterAll(async () => {
	// The guard REPORTS leftovers — it never forgives them: a test that
	// forgets teardown must fail even when its directory is trivially
	// removable (removal drains belong in the creating test via
	// tests/remove-settled.ts). Settle first so in-flight writers are
	// measured at rest, and require two consecutive EMPTY polls before
	// declaring the run clean — a writer that has not created its
	// directory yet must not slip through the first empty read.
	let entries = readdirSync(RUN_TMP_ROOT);
	for (let i = 0; i < 20; i += 1) {
		await new Promise((resolve) => setTimeout(resolve, 40));
		const next = readdirSync(RUN_TMP_ROOT);
		if (next.length === 0 && entries.length === 0) break;
		if (next.length === entries.length && next.every((name, idx) => name === entries[idx]) && i >= 1) break;
		entries = next;
	}
	try {
		if (entries.length > 0) {
			throw new Error(
				`pi-agents-tmux tests leaked ${entries.length} tmp dir(s); add teardown in the creating test file (see tests/remove-settled.ts): ${entries.slice(0, 12).join(", ")}`,
			);
		}
	} finally {
		rmSync(RUN_TMP_ROOT, { force: true, recursive: true });
	}
});

// The suite's own tmux server. The launching shell's TMUX and TMUX_PANE
// can name a developer's live server and pane. Drop them before any test
// module loads, then point at a server this run starts and kills, so every real tmux
// call from this process or a child lands there. The session's command
// exits once this process is gone, which closes the server after a crash
// too. A tmux that cannot start is a failed run, never a silent fallback
// to the launching server.
delete process.env.TMUX;
delete process.env.TMUX_PANE;
const TMUX_SERVER_NAME = `pi-agents-tmux-tests-${process.pid}`;
const tmuxServer = (args: string[]) => childProcess.spawnSync("tmux", ["-L", TMUX_SERVER_NAME, ...args], { encoding: "utf8", env: process.env });
const started = tmuxServer(["-f", "/dev/null", "new-session", "-d", "-s", "tests", "sh", "-c", `while kill -0 ${process.pid} 2>/dev/null; do sleep 5; done`]);
if (started.error || started.status !== 0) {
	throw new Error(`pi-agents-tmux tests need a tmux server of their own and could not start one: ${started.error ?? started.stderr.trim()}`);
}
const world = tmuxServer(["display-message", "-p", "#{socket_path},#{pid},#{session_id}\t#{pane_id}"]).stdout.trim();
const [tmuxEnv, tmuxPane] = world.split("\t");
if (!tmuxEnv || !tmuxPane) throw new Error(`pi-agents-tmux tests could not read their tmux server back: ${JSON.stringify(world)}`);
process.env.TMUX = tmuxEnv.replace(",$", ",");
process.env.TMUX_PANE = tmuxPane;

afterAll(() => {
	// tmux leaves the socket file behind when the server exits.
	tmuxServer(["kill-server"]);
	rmSync(tmuxEnv.split(",")[0]!, { force: true });
});

// Bun's spawnSync and execFileSync hand a child the environment this
// process STARTED with unless `env` is given, so the deletion above would
// not reach them; spawn reads the live process.env. The fixture git calls
// (single-agent-fixture.ts, needs-completion-fixture.ts,
// cwd-snapshot-dirty-status.test.ts) and the launcher runs in
// pi-invocation.test.ts are the sync producers. A caller's own env wins.
const realChildProcess = { ...childProcess };
type SyncOptions = Record<string, unknown> | undefined;
const withLiveEnv = (options: SyncOptions) => ({ env: process.env, ...(options ?? {}) });
mock.module("node:child_process", () => ({
	...realChildProcess,
	execFileSync: (command: string, args?: string[] | SyncOptions, options?: SyncOptions) =>
		Array.isArray(args)
			? realChildProcess.execFileSync(command, args, withLiveEnv(options))
			: realChildProcess.execFileSync(command, withLiveEnv(args)),
	spawnSync: (command: string, args?: string[] | SyncOptions, options?: SyncOptions) =>
		Array.isArray(args)
			? realChildProcess.spawnSync(command, args, withLiveEnv(options))
			: realChildProcess.spawnSync(command, withLiveEnv(args)),
}));

// Minimal typebox surface used by extensions/subagent/tools.ts; typebox is an
// uninstalled peer dependency in this checkout, mocked like the pi peers below.
mock.module("typebox", () => {
	const withOptions = (schema: Record<string, unknown>, options?: Record<string, unknown>) => ({
		...(options ?? {}),
		...schema,
	});
	return {
		Type: {
			Array: (items: unknown, options?: Record<string, unknown>) => withOptions({ items, type: "array" }, options),
			Boolean: (options?: Record<string, unknown>) => withOptions({ type: "boolean" }, options),
			Number: (options?: Record<string, unknown>) => withOptions({ type: "number" }, options),
			Object: (properties: Record<string, unknown>, options?: Record<string, unknown>) =>
				withOptions({ properties, type: "object" }, options),
			Optional: (schema: Record<string, unknown>) => ({ ...schema }),
			String: (options?: Record<string, unknown>) => withOptions({ type: "string" }, options),
		},
	};
});

mock.module("@earendil-works/pi-coding-agent", () => {
	const truncate = (text: string, limits: { maxBytes: number; maxLines: number }, fromTail = false) => {
		const lines = text.split(/\r?\n/);
		const selectedLines = fromTail ? lines.slice(-limits.maxLines) : lines.slice(0, limits.maxLines);
		let content = selectedLines.join("\n");
		if (Buffer.byteLength(content) > limits.maxBytes) content = content.slice(0, limits.maxBytes);
		return {
			content,
			outputBytes: Buffer.byteLength(content),
			outputLines: selectedLines.length,
			totalBytes: Buffer.byteLength(text),
			totalLines: lines.length,
			truncated: content !== text,
		};
	};
	return {
		formatSize(bytes: number) {
			return `${bytes} B`;
		},
		getAgentDir() {
			return process.env.PI_CODING_AGENT_DIR ?? "/tmp/pi-agent-test";
		},
		getMarkdownTheme() {
			return {};
		},
		parseFrontmatter(content: string) {
			const match = content.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
			if (!match) return { frontmatter: {}, body: content };
			const frontmatter: Record<string, unknown> = {};
			for (const line of match[1].split(/\r?\n/)) {
				const separator = line.indexOf(":");
				if (separator < 0) continue;
				frontmatter[line.slice(0, separator).trim()] = line.slice(separator + 1).trim();
			}
			return { frontmatter, body: match[2] };
		},
		truncateHead(text: string, limits: { maxBytes: number; maxLines: number }) {
			return truncate(text, limits, false);
		},
		truncateTail(text: string, limits: { maxBytes: number; maxLines: number }) {
			return truncate(text, limits, true);
		},
		async withFileMutationQueue<T>(_filePath: string, fn: () => Promise<T>): Promise<T> {
			return fn();
		},
	};
});

mock.module("@earendil-works/pi-tui", () => {
	class Container {
		children: unknown[] = [];
		addChild(child: unknown) { this.children.push(child); }
		render() { return []; }
	}
	class Spacer {
		render() { return [""]; }
	}
	return {
		Container,
		Markdown: Container,
		matchesKey() {
			return false;
		},
		Spacer,
		truncateToWidth(text: string, width: number, suffix = "") {
			return text.length > width ? `${text.slice(0, Math.max(0, width - suffix.length))}${suffix}` : text;
		},
		visibleWidth(text: string) {
			return text.replace(/\x1b\[[0-9;]*m/g, "").length;
		},
		wrapTextWithAnsi(text: string, _width: number) {
			return text.split(/\r?\n/);
		},
	};
});

mock.module("@earendil-works/pi-ai", () => ({
	StringEnum(values: readonly string[], options?: Record<string, unknown>) {
		return { ...options, enum: values, type: "string" };
	},
}));
