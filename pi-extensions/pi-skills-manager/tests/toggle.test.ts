import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { clearPackageConfigCache, recordProjectTrust } from "../extensions/skills-manager/package-config.ts";
import { loadSkillRegistry } from "../extensions/skills-manager/registry.ts";
import { setSkillEnabled } from "../extensions/skills-manager/toggle.ts";

const keys = ["HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "PI_CODING_AGENT_DIR"] as const;
const previous = new Map(keys.map((key) => [key, process.env[key]]));
let root: string;
let cwd: string;
let agentDir: string;

beforeAll(() => {
	root = mkdtempSync(join(tmpdir(), "pi-skills-manager-toggle-"));
	cwd = join(root, "project");
	agentDir = join(root, "home", ".pi", "agent");
	for (const key of keys) {
		process.env[key] = key === "HOME" ? join(root, "home") : key === "PI_CODING_AGENT_DIR" ? agentDir : join(root, key);
	}
	for (const dir of [cwd, agentDir]) mkdirSync(dir, { recursive: true });
	clearPackageConfigCache();
	recordProjectTrust({ cwd, isProjectTrusted: () => true } as Parameters<typeof recordProjectTrust>[0]);
});

afterAll(() => {
	for (const key of keys) {
		const value = previous.get(key);
		if (value === undefined) delete process.env[key];
		else process.env[key] = value;
	}
	clearPackageConfigCache();
	rmSync(root, { recursive: true, force: true });
});

// Pi 1.5.2 core/package-manager.js addAutoDiscoveredResources records the
// parent of .agents/skills, and matches exact overrides relative to that base.
test.each([
	{ location: "agents", scope: "user", recordedBase: true },
	{ location: "agent", scope: "user", recordedBase: true },
	{ location: "project", scope: "project", recordedBase: true },
	{ location: "agent", scope: "user", recordedBase: false },
	{ location: "project", scope: "project", recordedBase: false },
] as const)("$location skill toggles persist with recordedBase=$recordedBase", async ({ location, scope, recordedBase }) => {
	const name = `${location}-${recordedBase}`;
	const baseDir = location === "agents" ? join(root, "home", ".agents") : scope === "project" ? join(cwd, ".pi") : agentDir;
	const path = join(baseDir, "skills", name, "SKILL.md");
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, `---\nname: ${name}\ndescription: Toggle fixture.\n---\n`);
	const discovered = (await loadSkillRegistry(cwd)).allSkills.find((skill) => skill.path === path)!;
	expect(discovered).toBeDefined();
	expect(discovered.baseDir).toBe(baseDir);
	const skill = recordedBase ? discovered : { ...discovered, baseDir: undefined };
	const settingsPath = join(scope === "project" ? join(cwd, ".pi") : agentDir, "settings.json");
	const pattern = `skills/${name}/SKILL.md`;
	for (const enabled of [false, true]) {
		await setSkillEnabled(cwd, skill, enabled);
		const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
		expect(settings.skills).toContain(`${enabled ? "+" : "-"}${pattern}`);
		expect(settings.skills).not.toContain(`${enabled ? "-" : "+"}${pattern}`);
		const reloaded = (await loadSkillRegistry(cwd)).allSkills.find((entry) => entry.path === path)!;
		expect(reloaded.enabled).toBe(enabled);
	}
});
