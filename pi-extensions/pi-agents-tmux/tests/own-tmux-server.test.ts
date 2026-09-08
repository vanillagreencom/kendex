// The suite's tmux world, set up in tests/preload.ts: a pane title set
// through the real code path lands on the server this run started, never on
// another test-owned server, and a child spawned with the default
// environment carries the same values this process holds. A scratch server
// plays the launching shell's server so both rows use stable panes owned by
// this test.
import { test } from "bun:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { rmSync } from "node:fs";
import { setCurrentTmuxPaneTitle } from "../extensions/subagent/pane.js";

interface TmuxWorld {
	socket: string;
	TMUX: string;
	TMUX_PANE: string;
}

function tmuxAt(socket: string, args: string[]): string {
	const result = spawnSync("tmux", ["-S", socket, ...args], { encoding: "utf8" });
	assert.equal(result.status, 0, `tmux -S ${socket} ${args.join(" ")}: ${result.stderr}`);
	return result.stdout.trim();
}

function worldFromEnv(TMUX: string, TMUX_PANE: string): TmuxWorld {
	return { socket: TMUX.split(",")[0]!, TMUX, TMUX_PANE };
}

// `#{window_name}` and `#{pane_title}` of the pane the world's TMUX_PANE names.
function paneLabel(world: TmuxWorld): string {
	return tmuxAt(world.socket, ["display-message", "-p", "-t", world.TMUX_PANE, "#{window_name}\t#{pane_title}"]);
}

function startScratchServer(): TmuxWorld {
	const name = `pi-agents-tmux-control-${process.pid}`;
	const started = spawnSync("tmux", ["-L", name, "-f", "/dev/null", "new-session", "-d", "-s", "launching", "sh", "-c", `while kill -0 ${process.pid} 2>/dev/null; do sleep 5; done`], { encoding: "utf8" });
	assert.equal(started.status, 0, `scratch tmux server: ${started.stderr}`);
	const [TMUX, TMUX_PANE] = spawnSync("tmux", ["-L", name, "display-message", "-p", "#{socket_path},#{pid},#{session_id}\t#{pane_id}"], { encoding: "utf8" }).stdout.trim().split("\t");
	return worldFromEnv(TMUX!.replace(",$", ","), TMUX_PANE!);
}

function childSees(): string {
	return spawnSync("sh", ["-c", 'printf "%s|%s" "$TMUX" "$TMUX_PANE"'], { encoding: "utf8" }).stdout;
}

async function titleLanded(worlds: TmuxWorld[], title: string): Promise<void> {
	for (let i = 0; i < 60; i += 1) {
		if (worlds.some((world) => paneLabel(world).endsWith(`\t${title}`))) return;
		await new Promise((resolve) => setTimeout(resolve, 50));
	}
}

// label | the environment the title is set under | expect: where the title and the child's values landed
const rows: Array<[string, "suite" | "launching", string]> = [
	["the suite's environment: the title lands on the suite's own server", "suite", "suite=agent:control-suite launching=unchanged child=suite"],
	["the launching shell's environment restored: the title lands on the launching server", "launching", "suite=unchanged launching=agent:control-launching child=launching"],
];

test("a pane title set by the suite lands on its own tmux server", async () => {
	const suite = worldFromEnv(process.env.TMUX ?? "", process.env.TMUX_PANE ?? "");
	assert.ok(suite.TMUX && suite.TMUX_PANE, "the preload left no suite tmux server in the environment");
	const launching = startScratchServer();
	assert.notEqual(launching.socket, suite.socket, "the control server is the suite server");
	try {
		for (const [label, env, expect] of rows) {
			const world = env === "suite" ? suite : launching;
			process.env.TMUX = world.TMUX;
			process.env.TMUX_PANE = world.TMUX_PANE;
			const before = { suite: paneLabel(suite), launching: paneLabel(launching) };
			const title = `agent:control-${env}`;
			setCurrentTmuxPaneTitle(title);
			await titleLanded([suite, launching], title);
			const after = { suite: paneLabel(suite), launching: paneLabel(launching) };
			const landed = (key: "suite" | "launching") => (after[key] === before[key] ? "unchanged" : after[key].split("\t")[1]);
			const seen = childSees().split("|")[0]?.split(",")[0];
			const child = seen === suite.socket ? "suite" : seen === launching.socket ? "launching" : `other(${seen})`;
			assert.equal(`suite=${landed("suite")} launching=${landed("launching")} child=${child}`, expect, label);
		}
	} finally {
		process.env.TMUX = suite.TMUX;
		process.env.TMUX_PANE = suite.TMUX_PANE;
		// No assertion here: a teardown failure must not replace a row's.
		spawnSync("tmux", ["-S", launching.socket, "kill-server"], { stdio: "ignore" });
		rmSync(launching.socket, { force: true });
	}
});
