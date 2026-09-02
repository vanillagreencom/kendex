import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { runCommand } from "./process.js";
import type { InventoryItem } from "./types.js";

const SCRIPT_NAME = "append-system.mjs";
// A package-supplied script runs on every enable/disable toggle, on Pi's TUI
// thread. A hung write to a network-mounted scope root, or a script that reads
// stdin, would wedge it with no way out.
const APPEND_SYSTEM_TIMEOUT_MS = 10_000;

/**
 * Pi extension packages can declare `pi.appendSystem` in their package.json,
 * pointing at a markdown file whose contents are mirrored into the scope's
 * `APPEND_SYSTEM.md` so models receive extension-specific tool-usage rules.
 *
 * The upsert/remove logic lives in one place per package: the vendored
 * `scripts/append-system.mjs` npm already runs at `postinstall` and
 * `preuninstall`. Enable/disable and uninstall run that same script, which
 * resolves the scope from its own package dir.
 *
 * The script is deliberately best-effort for npm's sake: it exits 0 on every
 * failure and reports only on stderr, so the exit status alone says nothing.
 * Everything it writes to stderr is surfaced here instead of dropped.
 */
function runAppendSystemScript(packageDir: string | undefined, action: "install" | "remove"): boolean {
	// A dir that is gone takes its manifest with it, so nothing here can say
	// whether the package ever wrote a block. On `remove` that is a failure:
	// the block may be sitting in APPEND_SYSTEM.md with nothing left to remove
	// it. On `install` there is no package to install a block for.
	if (!packageDir || !existsSync(packageDir)) {
		if (action === "install") return true;
		console.warn(`pi-extension-manager: cannot run append-system remove, the package directory (${packageDir ?? "unknown"}) is gone; any APPEND_SYSTEM.md block it left is still there`);
		return false;
	}
	// The dir is here, so the manifest decides before anything looks at the
	// script: a package declaring no pi.appendSystem never had a block, and
	// running the script for it only earns the script's own complaint about
	// the missing declaration. An unreadable manifest is not an answer, so it
	// falls through and lets the script be the one to report.
	const declaration = declaresAppendSystem(packageDir);
	if (declaration === "absent") return true;
	const script = join(packageDir, "scripts", SCRIPT_NAME);
	if (!existsSync(script)) {
		const why = declaration === "declared" ? "declares pi.appendSystem but" : "has an unreadable package.json and";
		console.warn(`pi-extension-manager: ${packageDir} ${why} ships no scripts/${SCRIPT_NAME}; APPEND_SYSTEM.md not updated`);
		return false;
	}
	const result = runCommand("node", [script, action], { cwd: packageDir, killSignal: "SIGKILL", timeout: APPEND_SYSTEM_TIMEOUT_MS });
	const stderr = (result.stderr ?? "").trim();
	const status = result.status ?? 0;
	// The deadline is tested first: spawnSync sets error ETIMEDOUT *and* a
	// signal when it kills a child on timeout, so `result.error` alone would
	// report the cap as "never started".
	const timedOut = Boolean(result.signal) || (result.error as NodeJS.ErrnoException | undefined)?.code === "ETIMEDOUT";
	if (timedOut) {
		console.warn(`pi-extension-manager: append-system ${action} for ${packageDir} exceeded ${APPEND_SYSTEM_TIMEOUT_MS}ms and was killed (${result.signal ?? "no signal"})${stderr ? `: ${stderr}` : ""}`);
		return false;
	}
	if (result.error) {
		console.warn(`pi-extension-manager: append-system ${action} failed to launch for ${packageDir}: ${String(result.error)}`);
		return false;
	}
	// Only the script's own lines are a verdict. Everything else on stderr is
	// the node process talking, an ExperimentalWarning from the user's
	// NODE_OPTIONS being the common one, and must not turn a written block into
	// a reported failure. The bare name, not `${SCRIPT_NAME}:`, because the one
	// handler for a failed write reads `append-system.mjs (install) for ...`.
	// Node's own stderr never starts with it: a warning starts "(node:", a
	// stack frame trims to "at ", a syntax error to an absolute path.
	const reported = stderr.split("\n").filter((line) => line.trimStart().startsWith(SCRIPT_NAME));
	if (reported.length > 0 || status !== 0) {
		const detail = reported.length > 0 ? reported.join("; ") : stderr || "no output";
		console.warn(`pi-extension-manager: append-system ${action} reported a problem for ${packageDir} (exit ${status}): ${detail}`);
		return false;
	}
	if (stderr) console.warn(`pi-extension-manager: append-system ${action} for ${packageDir} wrote to stderr but reported no problem: ${stderr}`);
	return true;
}

/**
 * Whether the package asks for an APPEND_SYSTEM.md block at all. Three answers,
 * not two: an unreadable manifest is not the same as one that declares nothing,
 * and treating it as such would skip a package that may well want a block.
 */
function declaresAppendSystem(packageDir: string): "declared" | "absent" | "unreadable" {
	try {
		const manifest = JSON.parse(readFileSync(join(packageDir, "package.json"), "utf8")) as { pi?: { appendSystem?: unknown } };
		return typeof manifest?.pi?.appendSystem === "string" ? "declared" : "absent";
	} catch {
		return "unreadable";
	}
}

/** Returns false when the block was not written; the caller decides what to say. */
export function syncAppendSystemForPackage(item: InventoryItem, willDisable: boolean): boolean {
	if (item.kind !== "package" || !item.packageName) return true;
	return runAppendSystemScript(item.packageDir, willDisable ? "remove" : "install");
}

/**
 * APPEND_SYSTEM.md removal for both uninstall paths: the npm branch runs it
 * before `npm uninstall` deletes the tree the script lives in, and the orphan
 * branch runs it when stripping the settings entry is the only other cleanup.
 * Removal is keyed by package name and idempotent, so a `preuninstall` that
 * already won makes this a no-op.
 *
 * Scope note: the script falls back to `PI_CODING_AGENT_DIR` (or `~/.pi/agent`)
 * for a package dir outside a Pi-managed tree, so a legacy global-prefix
 * install's block lands in the user-global file. That is where the package's
 * own npm `postinstall` put it, so this is what can remove it again.
 */
export function removeAppendSystemBlockForUninstall(item: InventoryItem): boolean {
	if (!item.packageName) return true;
	return runAppendSystemScript(item.packageDir, "remove");
}

/** Restores a block stripped ahead of an uninstall that then failed. */
export function restoreAppendSystemBlockAfterFailedUninstall(item: InventoryItem): boolean {
	if (!item.packageName) return true;
	return runAppendSystemScript(item.packageDir, "install");
}
