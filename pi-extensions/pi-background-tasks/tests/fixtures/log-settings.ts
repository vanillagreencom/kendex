import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";

// The .pi boundary stops ancestor settings discovery in this private cwd.
export function privateLogRoot() {
	const scratch = resolve(import.meta.dir, "../../../..", "tmp");
	mkdirSync(scratch, { recursive: true });
	const root = realpathSync(mkdtempSync(join(scratch, "pi-log-results-")));
	try {
		mkdirSync(join(root, ".pi"));
		mkdirSync(join(root, "agent"));
		return root;
	} catch (error) {
		rmSync(root, { recursive: true, force: true });
		throw error;
	}
}

export function withLogSettings<T>(run: (cwd: string) => T): T {
	const root = privateLogRoot();
	const previous = process.env.PI_CODING_AGENT_DIR;
	try {
		process.env.PI_CODING_AGENT_DIR = join(root, "agent");
		return run(root);
	} finally {
		if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previous;
		rmSync(root, { recursive: true, force: true });
	}
}
