import { existsSync } from "node:fs";
import { join } from "node:path";
import { managerNotice } from "./format.js";
import { commandFailure, runCommand } from "./process.js";
import type { InventoryItem } from "./types.js";

const APPEND_SYSTEM_DEADLINE_MS = 10_000;

/**
 * Pi extension packages can declare `pi.appendSystem` in their package.json,
 * pointing at a markdown file whose contents are mirrored into the scope's
 * `APPEND_SYSTEM.md` so models receive extension-specific tool-usage rules.
 *
 * The upsert/remove logic lives in one place per package: the vendored
 * `scripts/append-system.mjs` npm already runs at `postinstall` and
 * `preuninstall`. Enable/disable and orphan uninstall run the same script,
 * which resolves the scope from its own package dir. A package that ships no
 * script declares no `pi.appendSystem` and gets no block.
 */
async function runAppendSystemScript(packageDir: string | undefined, action: "install" | "remove", signal: AbortSignal): Promise<void> {
	if (!packageDir) return;
	const script = join(packageDir, "scripts", "append-system.mjs");
	if (!existsSync(script)) return;
	// A package-supplied script gates every toggle, so the wait is bounded.
	const failure = commandFailure(await runCommand("node", [script, action], { cwd: packageDir, deadlineMs: APPEND_SYSTEM_DEADLINE_MS, signal }));
	if (failure) throw new Error(managerNotice(`append-system-${failure.reason}`, `${action}:${script}`, failure.detail));
}

export async function syncAppendSystemForPackage(item: InventoryItem, willDisable: boolean, signal: AbortSignal): Promise<void> {
	if (item.kind !== "package" || !item.packageName) return;
	await runAppendSystemScript(item.packageDir, willDisable ? "remove" : "install", signal);
}

/**
 * APPEND_SYSTEM.md cleanup for an uninstall that npm's `preuninstall` did not
 * already do — the orphan path, where only the settings entry is removed and
 * the package tree stays on disk. Removing by package name is idempotent, so
 * running it after a `preuninstall` that already won is harmless.
 */
export async function removeAppendSystemBlockForUninstall(item: InventoryItem, signal: AbortSignal): Promise<void> {
	if (!item.packageName) return;
	await runAppendSystemScript(item.packageDir, "remove", signal);
}
