import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";

/** Explicit neutral dependencies for disposable source copies; no package lookup or install. */
export function isolatedHost(source: string): void {
	const modules = {
		"@earendil-works/pi-coding-agent": 'export const getAgentDir = () => process.env.PI_CODING_AGENT_DIR; export class SettingsManager {} export const getShellConfig = () => ({ shell: "sh", args: ["-c"] });',
		"@earendil-works/pi-tui": 'export const matchesKey = (input, key) => input === key; export const truncateToWidth = (text) => text; export const visibleWidth = (text) => text.length; export const wrapTextWithAnsi = (text) => [text];',
	};
	for (const [name, contents] of Object.entries(modules)) {
		const dir = join(source, "node_modules", name);
		mkdirSync(dir, { recursive: true });
		writeFileSync(join(dir, "package.json"), JSON.stringify({ name, type: "module", exports: "./index.js" }));
		writeFileSync(join(dir, "index.js"), contents);
	}
}

/** Locate the declared peer or the installed Pi CLI, without resolving through Bun's installer. */
export function installedPiRoot(): string {
	const require = createRequire(import.meta.url);
	const name = "@earendil-works/pi-coding-agent";
	// Bun's mock.module can make require.resolve return the virtual module name.
	// Read Node's dependency search directories instead of that mocked answer.
	for (const modules of require.resolve.paths(name) ?? []) {
		const dir = join(modules, name);
		const manifest = join(dir, "package.json");
		if (existsSync(manifest) && JSON.parse(readFileSync(manifest, "utf8")).name === name) return realpathSync(dir);
	}
	const cli = Bun.which("pi");
	if (!cli) throw new Error("sdk-fixture: missing Pi peer and CLI");
	const entry = realpathSync(cli);
	let dir = dirname(entry);
	for (;;) {
		const manifest = join(dir, "package.json");
		if (existsSync(manifest) && JSON.parse(readFileSync(manifest, "utf8")).name === "@earendil-works/pi-coding-agent") return dir;
		const parent = dirname(dir);
		if (parent === dir) throw new Error(`sdk-fixture: package root not found for ${entry}`);
		dir = parent;
	}
}
