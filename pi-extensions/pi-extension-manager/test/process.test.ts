import { expect, test } from "bun:test";
import { runCommand } from "../extensions/manager/process.ts";
import { testPi } from "./fixtures/exec.ts";

// Real waits exercise the host-call deadline, not Date.now(). The fake host never delivers.
test("runCommand returns a timeout and cancels a host call that never exits", async () => {
	let signal: AbortSignal | undefined;
	const pi = testPi(async (_command, _args, options) => {
		signal = options?.signal;
		return new Promise(() => {});
	});
	const result = await runCommand(pi, "npm", ["install", "example"], { signal: new AbortController().signal, timeout: 5 });
	expect(result).toEqual({ ok: false, cause: "timeout", detail: "Command exceeded 5 ms." });
	expect(signal?.aborted).toBe(true);
});

test("runCommand delivers cancellation without waiting for the host", async () => {
	const controller = new AbortController();
	let signal: AbortSignal | undefined;
	const pi = testPi(async (_command, _args, options) => {
		signal = options?.signal;
		controller.abort();
		return new Promise(() => {});
	});
	const result = await runCommand(pi, "npm", ["root"], { signal: controller.signal, timeout: 4_000 });
	expect(result).toEqual({ ok: false, cause: "cancelled", detail: "Command cancelled." });
	expect(signal?.aborted).toBe(true);
});
