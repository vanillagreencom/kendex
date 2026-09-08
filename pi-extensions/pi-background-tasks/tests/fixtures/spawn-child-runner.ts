import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

export function runSpawnFixture(fixture: string, input: Record<string, unknown>): unknown {
	const scratch = resolve(import.meta.dir, "../../../..", "tmp");
	mkdirSync(scratch, { recursive: true });
	const root = realpathSync(mkdtempSync(join(scratch, "spawn-hardening-")));
	try {
		for (const name of [".pi", "home", "agent", "logs"]) mkdirSync(join(root, name));
		writeFileSync(join(root, "agent", "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-background-tasks": {
			showWidget: false, resourceControlEnabled: input.resource === true, resourceControlMode: "systemd-run", forceKillGraceMs: 5000,
		} } } } }));
		const child = spawnSync(process.execPath, [join(import.meta.dir, fixture)], {
			cwd: root,
			env: { ...process.env, HOME: join(root, "home"), USERPROFILE: join(root, "home"), PI_CODING_AGENT_DIR: join(root, "agent"), PI_BG_TASK_DIR: join(root, "logs"), PI_BG_TASK_DIAGNOSTIC_LOG: join(root, "diagnostics.log") },
			input: JSON.stringify(input), encoding: "utf8", timeout: 10_000, killSignal: "SIGKILL", maxBuffer: 2_000_000,
		});
		if (child.error) throw new Error(`spawn_fixture.spawn_error=${child.error.code ?? child.error.name}\n${child.error.message}`);
		if (child.status !== 0) throw new Error(`spawn_fixture.child_exit=${child.status ?? child.signal}\n${child.stderr}`);
		return JSON.parse(child.stdout);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
}
