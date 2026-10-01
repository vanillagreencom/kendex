import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { managerNotice } from "./format.js";
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
async function runAppendSystemScript(pi: ExtensionAPI, signal: AbortSignal, packageDir: string | undefined, action: "install" | "remove"): Promise<void> {
	if (!packageDir) return;
	const script = join(packageDir, "scripts", "append-system.mjs");
	if (!existsSync(script)) return;
	const result = await runCommand(pi, "node", [script, action], { cwd: packageDir, signal, timeout: APPEND_SYSTEM_TIMEOUT_MS });
	if (!result.ok) throw new Error(managerNotice(`append-system-${result.cause}`, `${action}:${script}`, result.detail));
}

export async function syncAppendSystemForPackage(pi: ExtensionAPI, signal: AbortSignal, item: InventoryItem, willDisable: boolean): Promise<void> {
	if (item.kind !== "package" || !item.packageName) return;
	await runAppendSystemScript(pi, signal, item.packageDir, willDisable ? "remove" : "install");
}

/**
 * APPEND_SYSTEM.md cleanup for an uninstall that npm's `preuninstall` did not
 * already do — the orphan path, where only the settings entry is removed and
 * the package tree stays on disk. Removing by package name is idempotent, so
 * running it after a `preuninstall` that already won is harmless.
 */
export async function removeAppendSystemBlockForUninstall(pi: ExtensionAPI, signal: AbortSignal, item: InventoryItem): Promise<void> {
	if (!item.packageName) return;
	await runAppendSystemScript(pi, signal, item.packageDir, "remove");
}
