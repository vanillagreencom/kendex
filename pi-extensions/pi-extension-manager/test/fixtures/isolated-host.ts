import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

/** Explicit neutral dependencies for disposable source copies; no package lookup or install. */
export function isolatedHost(source: string): void {
	const modules = {
		"@earendil-works/pi-coding-agent": 'export const getAgentDir = () => process.env.PI_CODING_AGENT_DIR; export class SettingsManager {}',
		"@earendil-works/pi-tui": 'export const matchesKey = (input, key) => input === key; export const truncateToWidth = (text) => text; export const visibleWidth = (text) => text.length; export const wrapTextWithAnsi = (text) => [text];',
	};
	for (const [name, contents] of Object.entries(modules)) {
		const dir = join(source, "node_modules", name);
		mkdirSync(dir, { recursive: true });
		writeFileSync(join(dir, "package.json"), JSON.stringify({ name, type: "module", exports: "./index.js" }));
		writeFileSync(join(dir, "index.js"), contents);
	}
}
