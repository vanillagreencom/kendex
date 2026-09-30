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

test("shell minimizer keeps the first 20 lines, the last 80 and every important line", () => {
	withConfig({}, (cwd) => {
		const lines = Array.from({ length: 130 }, (_, i) => i === 35 ? "error: line 35" : `   Compiling crate_${i}`);
		const result = minimizeShellOutput(lines.join("\r\n"), "cargo build", cwd);
		expect(result.dropped).toBe(29);
		// `null` stands for the explanation line under each notice key.
		const expected = [...lines.slice(0, 20), "[output-policy:minimized-lines=15]", null, lines[35], "[output-policy:minimized-lines=14]", null, ...lines.slice(50)];
		const out = result.text.split("\n");
		expect(out).toHaveLength(expected.length);
		expected.forEach((line, i) => { if (line !== null) expect(out[i]).toBe(line); });
	});
});
