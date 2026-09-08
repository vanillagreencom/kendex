import { afterEach, beforeEach, describe, expect, test } from "bun:test";
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

	test("pastes slash text literally and submits Enter", async () => {
		const calls: Array<[string, string[]]> = [];
		const exec: ExecLike = async (command, args) => {
			calls.push([command, args]);
			return { code: 0, stdout: "" };
		};
		await pasteAndSubmitToPane(exec, "%7", "/tasks:add foo");
		expect(calls).toEqual([
			["tmux", ["send-keys", "-t", "%7", "-l", "/tasks:add foo"]],
			["tmux", ["send-keys", "-t", "%7", "Enter"]],
		]);
	});
});
