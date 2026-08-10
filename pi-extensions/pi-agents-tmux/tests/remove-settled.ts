import { existsSync, rmSync } from "node:fs";

// Delete a test tempdir and VERIFY it stays gone: several extension paths
// persist lifecycle/task-registry writes fire-and-forget, and a plain rmSync
// can lose that race — the delayed write recreates the directory after
// cleanup and trips the suite-level leak guard. Two consecutive
// absent-checks confirm the writer has drained; a directory that keeps
// reappearing is an unawaited writer and fails loudly here, at its source.
export async function removeSettled(dir: string) {
	for (let i = 0; i < 20; i += 1) {
		rmSync(dir, { force: true, recursive: true });
		await new Promise((resolve) => setTimeout(resolve, 25));
		if (!existsSync(dir)) {
			await new Promise((resolve) => setTimeout(resolve, 25));
			if (!existsSync(dir)) return;
		}
	}
	rmSync(dir, { force: true, recursive: true });
	if (existsSync(dir)) {
		throw new Error(`tempdir ${dir} keeps being recreated by an unawaited writer`);
	}
}
