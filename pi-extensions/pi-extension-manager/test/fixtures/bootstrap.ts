import { mock } from "bun:test";
import { YAML } from "bun";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [root, kind, mode] = process.argv.slice(2);
assert(root && kind && mode);
const agent = join(root, "agent");
const cwd = join(root, "project");
const project = join(cwd, kind === "omp" ? ".omp" : ".pi");
mkdirSync(agent, { recursive: true });
mkdirSync(project, { recursive: true });
const config = (enabled: boolean) => ({ unknown: { keep: true }, kendex: { extensionManager: { config: { "@vanillagreen/pi-extension-manager": { enabled } } } } });
const userPath = join(agent, kind === "omp" ? "config.yaml" : "settings.json");
const projectPath = join(project, kind === "omp" ? "config.yml" : "settings.json");
const serialize = kind === "omp" ? YAML.stringify : JSON.stringify;
writeFileSync(userPath, serialize(config(mode === "enabled")));
writeFileSync(projectPath, serialize({ projectOnly: true }));
const projectBefore = readFileSync(projectPath, "utf8");

mock.module("@earendil-works/pi-coding-agent", () => ({ getAgentDir: () => agent, ...(kind === "omp" ? { Settings: class {} } : { SettingsManager: class {} }) }));
mock.module("@oh-my-pi/pi-utils", () => ({
	getAgentDir: () => agent, getPluginsDir: () => join(root, "plugins"), getProjectAgentDir: () => project,
	getProjectPluginOverridesPath: () => join(project, "plugin-overrides.json"),
}));
mock.module("@oh-my-pi/pi-coding-agent/discovery/helpers", () => ({ resolveActiveProjectRegistryPath: async () => null }));
const unused = () => { throw new Error("Bootstrap must not render a popup"); };
mock.module("@earendil-works/pi-tui", () => ({ matchesKey: unused, truncateToWidth: unused, visibleWidth: unused, wrapTextWithAnsi: unused }));
const { default: extensionManager } = await import("../../extensions/extension-manager.ts");
const commands = new Map<string, { handler(args: string, ctx: unknown): Promise<void> }>();
const api = { registerCommand: (name: string, command: { handler(args: string, ctx: unknown): Promise<void> }) => commands.set(name, command), registerShortcut() {}, on() {} };
await extensionManager(api as never);
const manager = kind === "omp" ? "kendex:extensions" : "extensions";
assert.deepEqual([...commands.keys()], mode === "disabled" ? [manager, `${manager}:enable`] : [manager, `${manager}:settings`]);
if (mode === "disabled") {
	await commands.get(`${manager}:enable`)!.handler("", { cwd, isProjectTrusted: () => true, ui: { notify() {} } });
	const parsed = (kind === "omp" ? YAML.parse : JSON.parse)(readFileSync(userPath, "utf8")) as ReturnType<typeof config>;
	assert.equal(parsed.kendex.extensionManager.config["@vanillagreen/pi-extension-manager"].enabled, true);
	assert.deepEqual(parsed.unknown, { keep: true });
	assert.equal(readFileSync(projectPath, "utf8"), projectBefore);
}
if (kind === "omp") assert.equal(existsSync(join(agent, "settings.json")), false);
