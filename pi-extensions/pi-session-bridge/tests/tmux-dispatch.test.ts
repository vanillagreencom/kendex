import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";
import { execFileSync } from "node:child_process";
import sessionBridge, { pasteAndSubmitToPane, resolveOwnTmuxPaneByParentChain, type ExecLike } from "../extensions/session-bridge.ts";
import { fakeCtx, fakePi, shutdownBridge, writeBridgeSettings } from "./lib/bridge-fixture.ts";
import { runCli } from "./lib/cli-fixture.ts";
import { dir, p, useSlashFixture } from "./lib/slash-fixture.ts";

let oldTmux: string | undefined;
beforeEach(() => { oldTmux = process.env.TMUX; });
afterEach(() => {
	if (oldTmux === undefined) delete process.env.TMUX;
	else process.env.TMUX = oldTmux;
});
useSlashFixture();

describe("tmux pane dispatch", () => {
	for (const row of [
		{ failure: "load-buffer", injected: false, fallback: true },
		{ failure: "paste-buffer", injected: false, fallback: true },
		{ failure: "display-message", injected: true, fallback: false },
		{ failure: "cancel", injected: true, fallback: false },
		{ failure: "Enter", injected: true, fallback: false },
		{ failure: "none", injected: true, fallback: false },
		{ failure: "control", injected: true, fallback: true },
	]) {
		test(`fallback after ${row.failure}`, async () => {
			writeBridgeSettings(dir);
			process.chdir(dir);
			process.env.PI_BRIDGE_DIR = p("bridge");
			process.env.TMUX = "fixture";
			let install = sessionBridge;
			if (row.failure === "control") {
				const source = fs.readFileSync(new URL("../extensions/session-bridge.ts", import.meta.url), "utf8");
				const check = "if (error instanceof PaneSubmissionError) throw error;";
				expect(source.split(check)).toHaveLength(2);
				const mutant = source.replace(check, "if (false && error instanceof PaneSubmissionError) throw error;");
				expect(mutant).not.toBe(source);
				fs.cpSync(new URL("../extensions/", import.meta.url), p("mutant"), { recursive: true });
				fs.writeFileSync(p("mutant/session-bridge.ts"), mutant);
				install = (await import(p("mutant/session-bridge.ts"))).default;
			}
			const { pi, handlers } = fakePi();
			const drafts: string[] = [], fallback: unknown[] = [];
			let loaded = "";
			pi.sendUserMessage = (content) => { fallback.push(content); };
			pi.exec = async (command, args) => {
				if (command === "ps") return { code: 0, stdout: "1", stderr: "" };
				if (args[0] === "list-panes") return { code: 0, stdout: `${process.pid} %7`, stderr: "" };
				const operation = args[0] === "send-keys" ? args.at(-1) : args[0];
				if (operation === (row.failure === "control" ? "cancel" : row.failure)) return { code: 1, stdout: "", stderr: "fixture failure" };
				if (operation === "load-buffer") loaded = fs.readFileSync(args.at(-1)!, "utf8");
				if (operation === "paste-buffer") drafts.push(loaded);
				return { code: 0, stdout: row.failure === "cancel" || row.failure === "control" ? "1" : "0", stderr: "" };
			};
			try {
				install(pi);
				await handlers.get("session_start")?.({ reason: "test" }, fakeCtx(dir));
				const result = await runCli(["request", "--socket", p(`bridge/pi-${process.pid}.sock`), JSON.stringify({ id: "send", type: "prompt", content: "/tasks:add foo" })]);
				const success = row.fallback || row.failure === "none";
				expect({ code: result.code, success: JSON.parse(result.stdout).success, drafts, fallback }).toEqual({
					code: success ? 0 : 1, success,
					drafts: row.injected ? ["/tasks:add foo"] : [],
					fallback: row.fallback ? ["/tasks:add foo"] : [],
				});
			} finally {
				await shutdownBridge(handlers, dir);
			}
		});
	}

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
