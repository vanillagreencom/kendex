import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { TestContext } from "node:test";

/** Own the project and settings directories until the case completes. */
export function world(t: Pick<TestContext, "after">) {
	const root = mkdtempSync(join(tmpdir(), "pi-codex-test-"));
	const cwd = join(root, "project");
	const agent = join(root, "agent");
	mkdirSync(join(cwd, ".pi"), { recursive: true });
	mkdirSync(agent);
	t.after(() => rmSync(root, { recursive: true, force: true }));
	return { root, cwd, agent };
}

/** Restore the complete environment change, including missing variables. */
export function environment(t: Pick<TestContext, "after">, values: Record<string, string | undefined>) {
	const previous = Object.fromEntries(Object.keys(values).map((key) => [key, process.env[key]]));
	const apply = (entries: Record<string, string | undefined>) => {
		for (const [key, value] of Object.entries(entries)) {
			if (value === undefined) delete process.env[key];
			else process.env[key] = value;
		}
	};
	t.after(() => apply(previous));
	apply(values);
}

/** Transport fixtures do not create dispatchers from the developer's proxy. */
export const noProxyEnvironment = {
	HTTP_PROXY: undefined, http_proxy: undefined, HTTPS_PROXY: undefined,
	https_proxy: undefined, ALL_PROXY: undefined, all_proxy: undefined,
	NO_PROXY: undefined, no_proxy: undefined,
};
