import { existsSync } from "node:fs";
import { join } from "node:path";
import { runCommand } from "./process.js";
import type { InventoryItem } from "./types.js";

const APPEND_SYSTEM_TIMEOUT_MS = 10_000;

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
function runAppendSystemScript(packageDir: string | undefined, action: "install" | "remove"): void {
	if (!packageDir) return;
	const script = join(packageDir, "scripts", "append-system.mjs");
	if (!existsSync(script)) return;
	// A package-supplied script runs on Pi's TUI thread at every toggle, so the
	// wait is bounded.
	const result = runCommand("node", [script, action], { cwd: packageDir, killSignal: "SIGKILL", timeout: APPEND_SYSTEM_TIMEOUT_MS });
	// Best-effort, like the script itself: never block a toggle or uninstall
	// on an APPEND_SYSTEM.md write.
	if (result.error) console.warn(`pi-extension-manager: append-system ${action} failed to launch: ${String(result.error)}`);
}

export function syncAppendSystemForPackage(item: InventoryItem, willDisable: boolean): void {
	if (item.kind !== "package" || !item.packageName) return;
	runAppendSystemScript(item.packageDir, willDisable ? "remove" : "install");
}

/**
 * APPEND_SYSTEM.md cleanup for an uninstall that npm's `preuninstall` did not
 * already do — the orphan path, where only the settings entry is removed and
 * the package tree stays on disk. Removing by package name is idempotent, so
 * running it after a `preuninstall` that already won is harmless.
 */
export function removeAppendSystemBlockForUninstall(item: InventoryItem): void {
	if (!item.packageName) return;
	runAppendSystemScript(item.packageDir, "remove");
}
