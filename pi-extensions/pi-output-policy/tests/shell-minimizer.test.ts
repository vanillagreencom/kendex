import { expect, test } from "bun:test";
import { minimizeShellOutput } from "../extensions/output-policy.ts";
import { withConfig } from "./fixtures.ts";

test("shell minimizer configuration", () => {
	const tail = "    Finished test profile [unoptimized] target(s) in 4.72s\ntest result: ok. 41 passed; 0 failed";
	for (const [config, enabled] of [[{}, true], [{ "shellMinimizer.enabled": false }, false]] as const) {
		withConfig(config, (cwd) => {
			const noisy = Array.from({ length: 180 }, (_, i) => `   Compiling crate_${i} v0.1.0`).join("\n");
			const text = `${noisy}\n${tail}`;
			const result = minimizeShellOutput(text, "cargo test", cwd);
			if (enabled) {
				expect(result.dropped).toBeGreaterThan(0);
				expect(result.text).toContain(`[output-policy:minimized-lines=${result.dropped}]`);
				expect(result.text).toContain(tail);
			} else {
				expect(result).toEqual({ text, dropped: 0 });
			}
		});
	}
});
