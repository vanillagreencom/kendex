import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import test from "node:test";
import { clearPackageConfigCache } from "../extensions/subagent/package-config.js";
import { ensurePersistentPane, setPaneExecCaptureForTests } from "../extensions/subagent/pane.js";
import { tempRuntime, withModelFixtureCapture } from "./single-agent-fixture.js";

test("C locale pane launch finds its process's pane and balances the columns", async () => {
	const root = tempRuntime();
	const socket = join(root, "s");
	// Use an outside client on the private C-locale server. Inherited TMUX
	// would make tmux assume UTF-8 even with LC_ALL=C.
	const env = { PATH: process.env.PATH, LC_ALL: "C" };
	const run = (args: string[]) => spawnSync("tmux", ["-S", socket, ...args], { env, encoding: "utf8", timeout: 3000 });
	const query = (...args: string[]) => {
		const result = run(args);
		assert.equal(result.status, 0, result.stderr || String(result.error));
		return result.stdout.trim();
	};
	const primary = query("-f", "/dev/null", "new-session", "-d", "-P", "-F", "#{pane_id}", "-s", "agents", "-x", "101", "-y", "24", "sleep", "300");
	const prev = { TMUX: process.env.TMUX, TMUX_PANE: process.env.TMUX_PANE,
		PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR, PI_BRIDGE_BIN: process.env.PI_BRIDGE_BIN };
	try {
		const parent = query("display-message", "-p", "-t", primary, "#{pane_pid}");
		process.env.TMUX = `${socket},1,0`;
		process.env.TMUX_PANE = query("new-window", "-P", "-F", "#{pane_id}", "-t", "agents:", "sleep", "300");
		process.env.PI_CODING_AGENT_DIR = root;
		delete process.env.PI_BRIDGE_BIN;
		clearPackageConfigCache();
		setPaneExecCaptureForTests(withModelFixtureCapture(async (command, args) => {
			if (command === "bash") return { code: 1, stdout: "", stderr: "" };
			if (command === "ps") {
				// The suite itself runs outside tmux. Present the primary pane's
				// real process as the caller's parent, ahead of the stale hint.
				assert.equal(args.at(-1), String(process.pid));
				return { code: 0, stdout: parent, stderr: "" };
			}
			assert.equal(command, "tmux");
			if (args[0] === "split-window") {
				// Keep the new pane alive without launching Pi and start with
				// unequal widths so skipping the rebalance changes the result.
				args = [...args.slice(0, -2), "sleep", "300"];
				args[args.indexOf("-p") + 1] = "20";
			}
			const result = run(args);
			return { code: result.status ?? 1, stdout: result.stdout, stderr: result.stderr, error: result.error };
		}));
		const agent = { name: "locale", description: "", systemPrompt: "", pane: true, source: "project", filePath: "locale.md" } as const;
		const entry = await ensurePersistentPane(root, "parent", root, agent, undefined, undefined);
		assert.equal(entry.primaryPaneId, primary, "the pane containing the parent process must win over the stale hint");
		const widths = [primary, entry.paneId].map((id) => Number(query("display-message", "-p", "-t", id, "#{pane_width}")));
		assert.deepEqual(widths, [50, 50], "the new agent column must have the same width as the parent column");
	} finally {
		setPaneExecCaptureForTests();
		for (const [key, value] of Object.entries(prev)) {
			if (value === undefined) delete process.env[key];
			else process.env[key] = value;
		}
		clearPackageConfigCache();
		query("kill-server");
	}
});
