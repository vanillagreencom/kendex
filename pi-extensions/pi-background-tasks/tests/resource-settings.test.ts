import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readResourceControlSettings, type ResourceControlSettings } from "../extensions/resource-control.js";

test("resource settings parse configured fields and clamp numeric values", () => {
	const defaults: ResourceControlSettings = {
		enabled: false, mode: "auto", applyToBgTask: true, applyToAutoBackground: true,
		cpuWeight: 100, ioWeight: 100, nice: 10, ioniceClass: "best-effort",
		ioniceLevel: 7, warnOnFallback: true,
	};
	const rows: { name: string; config?: Record<string, unknown>; expected: Partial<ResourceControlSettings> }[] = [
		{ name: "absent configuration uses complete defaults", expected: {} },
		{ name: "enabled setting is read", config: { resourceControlEnabled: true }, expected: { enabled: true } },
		{ name: "mode setting is read", config: { resourceControlMode: "nice-ionice" }, expected: { mode: "nice-ionice" } },
		{ name: "explicit task opt out is read", config: { resourceControlApplyToBgTask: false }, expected: { applyToBgTask: false } },
		{ name: "auto background opt out is read", config: { resourceControlApplyToAutoBackground: false }, expected: { applyToAutoBackground: false } },
		{ name: "CPU weight clamps at upper bound", config: { resourceControlCpuWeight: 50_000 }, expected: { cpuWeight: 10_000 } },
		{ name: "string IO weight parses and clamps at lower bound", config: { resourceControlIoWeight: "0" }, expected: { ioWeight: 1 } },
		{ name: "nice clamps at upper bound", config: { resourceControlNice: 42 }, expected: { nice: 19 } },
		{ name: "unknown ionice class uses default", config: { resourceControlIoniceClass: "not-a-class" }, expected: { ioniceClass: "best-effort" } },
		{ name: "ionice level clamps at lower bound", config: { resourceControlIoniceLevel: -5 }, expected: { ioniceLevel: 0 } },
		{ name: "fallback warning setting is read", config: { resourceControlWarnOnFallback: false }, expected: { warnOnFallback: false } },
		{
			name: "combined extension manager configuration preserves every parsed value",
			config: {
				resourceControlEnabled: true, resourceControlMode: "nice-ionice",
				resourceControlApplyToBgTask: false, resourceControlApplyToAutoBackground: false,
				resourceControlCpuWeight: 50_000, resourceControlIoWeight: "0", resourceControlNice: 42,
				resourceControlIoniceClass: "not-a-class", resourceControlIoniceLevel: -5, resourceControlWarnOnFallback: false,
			},
			expected: {
				enabled: true, mode: "nice-ionice", applyToBgTask: false, applyToAutoBackground: false,
				cpuWeight: 10_000, ioWeight: 1, nice: 19, ioniceClass: "best-effort", ioniceLevel: 0, warnOnFallback: false,
			},
		},
	];
	expect.assertions(rows.length + 1);
	expect(rows.length, "resource settings rows must not be empty").toBeGreaterThan(0);
	for (const row of rows) {
		const previousPiRoot = process.env.PI_CODING_AGENT_DIR;
		const root = mkdtempSync(join(tmpdir(), "pi-bg-rc-settings-"));
		try {
			const user = join(root, "user");
			process.env.PI_CODING_AGENT_DIR = user;
			if (row.config !== undefined) {
				mkdirSync(user, { recursive: true });
				writeFileSync(join(user, "settings.json"), JSON.stringify({
					kendex: { extensionManager: { config: { "@vanillagreen/pi-background-tasks": row.config } } },
				}));
			}
			expect(readResourceControlSettings(root), row.name).toEqual({ ...defaults, ...row.expected });
		} finally {
			if (previousPiRoot === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = previousPiRoot;
			rmSync(root, { recursive: true, force: true });
		}
	}
});
