import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";
import { execFileSync } from "node:child_process";
import { pasteAndSubmitToPane, resolveOwnTmuxPaneByParentChain, type ExecLike } from "../extensions/session-bridge.ts";

let oldTmux: string | undefined;
beforeEach(() => { oldTmux = process.env.TMUX; });
afterEach(() => {
	if (oldTmux === undefined) delete process.env.TMUX;
	else process.env.TMUX = oldTmux;
});

describe("tmux pane dispatch", () => {
	test("resolves own pane by parent chain, not active tmux client state", async () => {
		process.env.TMUX = "/tmp/tmux-1000/default,123,0";
		const calls: Array<[string, string[]]> = [];
		const exec: ExecLike = async (command, args) => {
			calls.push([command, args]);
			if (command === "tmux") return { code: 0, stdout: "100 %1\n250 %2\n" };
			const pid = args.at(-1);
			if (pid === "303") return { code: 0, stdout: "202\n" };
			if (pid === "202") return { code: 0, stdout: "100\n" };
			if (pid === "100") return { code: 0, stdout: "1\n" };
			return { code: 1, stderr: "missing pid" };
		};

		await expect(resolveOwnTmuxPaneByParentChain(exec, 303)).resolves.toBe("%1");
		expect(calls[0]).toEqual(["tmux", ["list-panes", "-a", "-F", "#{pane_pid} #{pane_id}"]]);
		expect(calls.some(([command, args]) => command === "tmux" && args[0] === "display-message")).toBe(false);
	});

	test("delivers text to the pane program in normal and copy mode", async () => {
		fs.mkdirSync("tmp", { recursive: true });
		const directory = fs.mkdtempSync(path.resolve("tmp/tmux-dispatch-"));
		const socket = path.basename(directory);
		const received = path.join(directory, "received");
		const tmux = (...args: string[]) => execFileSync("tmux", ["-L", socket, ...args], { encoding: "utf8" });
		try {
			const pane = tmux("-f", "/dev/null", "new-session", "-d", "-P", "-F", "#{pane_id}", `cat >> '${received}'`).trim();
			for (const mode of ["legacy-copy", "copy", "normal"]) {
				fs.writeFileSync(received, "");
				if (mode !== "normal") tmux("copy-mode", "-t", pane);
				expect(tmux("display-message", "-p", "-t", pane, "#{pane_in_mode}").trim()).toBe(mode === "normal" ? "0" : "1");
				if (mode === "legacy-copy") {
					tmux("send-keys", "-t", pane, "-l", "hello");
					tmux("send-keys", "-t", pane, "Enter");
				} else await pasteAndSubmitToPane(async (_command, args) => ({ code: 0, stdout: tmux(...args) }), pane, "hello");
				await Bun.sleep(100);
				expect(fs.readFileSync(received, "utf8")).toBe(mode === "legacy-copy" ? "" : "hello\n");
			}
		} finally {
			tmux("kill-server");
			fs.rmSync(directory, { recursive: true });
		}
	});
});
