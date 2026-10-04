import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { managerNotice } from "./format.js";
import { commandFailure, runCommand } from "./process.js";
import type { InventoryItem } from "./types.js";

/** A package-supplied script gates every toggle, so the wait is bounded. */
export const APPEND_SYSTEM_DEADLINE_MS = 10_000;

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
/**
 * A script run: `ran` exit 0 with no notice, `absent` the package ships no
 * script, `failed` any other end, with its notice.
 */
export type AppendSystemOutcome =
	| { kind: "ran" }
	| { kind: "absent" }
	| { kind: "failed"; message: string };

/** The package's script, or `undefined` when it ships none. */
function appendSystemScript(packageDir: string | undefined): string | undefined {
	if (!packageDir) return undefined;
	const script = join(packageDir, "scripts", "append-system.mjs");
	return existsSync(script) ? script : undefined;
}

/**
 * The one reader of the script's result. For the install and remove actions
 * passed here, the vendored script exits 0 after each `append-system:
 * <key>=<value>` notice it prints, and prints one on every path that could
 * not write or remove the block, so an exit 0 with a notice is a failure. The
 * notice is the script's own result; reading APPEND_SYSTEM.md instead would
 * need a second copy of its scope resolution.
 */
async function runAppendSystemScript(packageDir: string | undefined, action: "install" | "remove", signal: AbortSignal): Promise<AppendSystemOutcome> {
	const script = appendSystemScript(packageDir);
	if (!script) return { kind: "absent" };
	const result = await runCommand("node", [script, action], { cwd: dirname(dirname(script)), deadlineMs: APPEND_SYSTEM_DEADLINE_MS, signal });
	const failure = commandFailure(result);
	if (failure) return { kind: "failed", message: managerNotice(`append-system-${failure.reason}`, `${action}:${script}`, failure.detail) };
	if (result.kind !== "exited") throw new Error(`append-system: a run with no failure ended as ${result.kind}`);
	const notices = result.output.stderr.trim();
	if (notices.split("\n").some((line) => line.startsWith("append-system: "))) return { kind: "failed", message: managerNotice("append-system-notice", `${action}:${script}`, notices) };
	return { kind: "ran" };
}

export async function syncAppendSystemForPackage(item: InventoryItem, willDisable: boolean, signal: AbortSignal): Promise<void> {
	if (item.kind !== "package" || !item.packageName) return;
	const outcome = await runAppendSystemScript(item.packageDir, willDisable ? "remove" : "install", signal);
	if (outcome.kind === "failed") throw new Error(outcome.message);
}

/**
 * APPEND_SYSTEM.md cleanup for an uninstall that npm's `preuninstall` did not
 * already do — the orphan path, where only the settings entry is removed and
 * the package tree stays on disk. Removing by package name is idempotent, so
 * running it after a `preuninstall` that already won is harmless.
 */
export async function removeAppendSystemBlockForUninstall(item: InventoryItem, signal: AbortSignal): Promise<AppendSystemOutcome> {
	if (!item.packageName) return { kind: "absent" };
	return runAppendSystemScript(item.packageDir, "remove", signal);
}

/** A restore wrote the package's block, or `cause` says why it did not. */
export type RestoreOutcome = { kind: "restored" } | { kind: "not-restored"; cause: string };

/**
 * Put back the block an uninstall removed before it failed or was cancelled.
 * It runs under its own signal, bounded by the script deadline alone: the
 * uninstall's signal may already be aborted, by Escape or by session end. The
 * install upsert is idempotent, so restoring a block a failed removal left is
 * harmless.
 */
export async function restoreAppendSystemBlockAfterUninstall(item: InventoryItem): Promise<RestoreOutcome> {
	const outcome = await runAppendSystemScript(item.packageDir, "install", new AbortController().signal);
	switch (outcome.kind) {
		case "ran":
			return { kind: "restored" };
		case "absent":
			return { kind: "not-restored", cause: managerNotice("append-system-gone", item.packageDir ?? item.id, "The package's scripts/append-system.mjs is gone.") };
		case "failed":
			return { kind: "not-restored", cause: outcome.message };
		default: {
			const unreachable: never = outcome;
			throw new Error(`append-system: unknown outcome ${JSON.stringify(unreachable)}`);
		}
	}
}
