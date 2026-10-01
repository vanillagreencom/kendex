import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";

/** Bundle a runtime fixture for the Node host, optionally planting one defect. */
export async function runNodeFixture(fixture: string, mutation?: { file: string; from: string; to: string }, sourceRef?: string) {
	const scratch = resolve(import.meta.dir, "../../../..", "tmp");
	mkdirSync(scratch, { recursive: true });
	const root = realpathSync(mkdtempSync(join(scratch, "node-runtime-")));
	let mutations = 0;
	try {
		const result = await Bun.build({
			entrypoints: [join(import.meta.dir, fixture)], outdir: root, target: "node",
			plugins: mutation || sourceRef ? [{ name: "must-fail", setup(build) {
				const file = mutation?.file ?? "extensions/format.ts";
				build.onLoad({ filter: new RegExp(`${file.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}$`) }, async (args) => {
					const source = sourceRef ? execFileSync("git", ["show", `${sourceRef}:pi-extensions/pi-background-tasks/extensions/format.ts`], {
						cwd: scratch, env: { PATH: process.env.PATH }, encoding: "utf8",
					}) : await Bun.file(args.path).text();
					if (mutation && source.split(mutation.from).length !== 2) throw new Error("must-fail source match is not unique");
					const contents = mutation ? source.replace(mutation.from, mutation.to) : source;
					if (mutation && contents === source) throw new Error("must-fail source did not change");
					mutations += 1;
					return { contents, loader: "ts" };
				});
			} }] : [],
		});
		if (!result.success) throw new Error(`Node fixture build failed: ${result.logs.join("\n")}`);
		if ((mutation || sourceRef) && mutations !== 1) throw new Error(`must-fail changed ${mutations} modules`);
		const child = spawnSync("node", [result.outputs[0].path], {
			env: { PATH: process.env.PATH, HOME: root, PI_CODING_AGENT_DIR: root, PI_OFFLINE: "1" },
			cwd: root, encoding: "utf8", timeout: 2_000, killSignal: "SIGKILL", maxBuffer: 100_000,
		});
		return { status: child.status, error: child.error?.code, signal: child.signal, stdout: child.stdout, stderr: child.stderr };
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
}
