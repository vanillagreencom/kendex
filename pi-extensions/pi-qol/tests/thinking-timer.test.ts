import { expect, test } from "bun:test";
import { rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { scratch } from "./search-fixture.ts";

// Surface: thinking-timer.ts's use of the installed AssistantMessageComponent.
// Inputs: thinking-timer.probe.ts, thinking-timer.ts, constants.ts, settings.ts,
// package-config.ts, search-fixture.ts and the installed Pi peers.
test("the thinking timer updates the native hidden-thinking label", () => {
	const home = scratch(resolve(import.meta.dir, "../tmp"));
	try {
		for (const mode of ["native", "direct-only"]) {
			const run = Bun.spawnSync([process.execPath, "--no-install", join(import.meta.dir, "thinking-timer.probe.ts"), mode], {
				cwd: resolve(import.meta.dir, ".."), env: { HOME: home, TMPDIR: home }, stdout: "pipe", stderr: "pipe", timeout: 10_000,
			});
			if (mode === "native") {
				expect({ exit: run.exitCode, stdout: run.stdout.toString(), stderr: run.stderr.toString() }).toEqual({ exit: 0, stdout: "thinking-timer: proved\n", stderr: "" });
			} else {
				// Must-fail control removes only the one-hop unwrap in a disposable copy.
				expect({ exit: run.exitCode, stderr: run.stderr.toString() }).toEqual({ exit: 1, stderr: "thinking-timer: elapsed-missing case=streaming\n" });
			}
		}
	} finally { rmSync(home, { recursive: true, force: true }); }
});
