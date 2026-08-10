import { existsSync, rmSync } from "node:fs";

// Delete a test tempdir and VERIFY it stays gone: several extension paths
// persist lifecycle/task-registry writes fire-and-forget, and a plain rmSync
// can lose that race — the delayed write recreates the directory after
// cleanup and trips the suite-level leak guard. A writer can legitimately
// stay filesystem-idle for seconds before its terminal write (the
// cwd-snapshot path awaits git first), so the drain is patient: up to ~8s,
// and "gone" means two consecutive absent checks. A directory that still
// keeps reappearing is an unawaited writer and fails loudly here, at its
// source — including after the final fallback removal.
export async function removeSettled(dir: string) {
	for (let i = 0; i < 80; i += 1) {
		rmSync(dir, { force: true, recursive: true });
		await new Promise((resolve) => setTimeout(resolve, 50));
		if (!existsSync(dir)) {
			await new Promise((resolve) => setTimeout(resolve, 50));
			if (!existsSync(dir)) return;
		}
	}
	rmSync(dir, { force: true, recursive: true });
	await new Promise((resolve) => setTimeout(resolve, 50));
	if (existsSync(dir)) {
		throw new Error(`tempdir ${dir} keeps being recreated by an unawaited writer`);
	}
	await new Promise((resolve) => setTimeout(resolve, 50));
	if (existsSync(dir)) {
		throw new Error(`tempdir ${dir} was recreated after its final removal — drain the writer in the creating test`);
	}
}
