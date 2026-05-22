import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { discoverAgents } from "../extensions/subagent/agents.js";

function tempProject(): string {
	const root = mkdtempSync(join(tmpdir(), "pi-agents-allowed-"));
	mkdirSync(join(root, ".pi", "agents"), { recursive: true });
	return root;
}

function writeAgent(root: string, name: string, frontmatterLines: string[]): void {
	const lines = ["---", `name: ${name}`, `description: ${name} test agent`, ...frontmatterLines, "---", ""];
	writeFileSync(join(root, ".pi", "agents", `${name}.md`), `${lines.join("\n")}\n`, "utf8");
}

describe("allowed-subagents parsing", () => {
	test("comma-separated string is split into a list", () => {
		const root = tempProject();
		writeAgent(root, "rust", ["allowed-subagents: scout, researcher"]);
		const { agents } = discoverAgents(root, "project");
		const rust = agents.find((agent) => agent.name === "rust");
		expect(rust?.allowedSubagents).toEqual(["scout", "researcher"]);
	});

	test("single name is preserved", () => {
		const root = tempProject();
		writeAgent(root, "rust", ["allowed-subagents: scout"]);
		const { agents } = discoverAgents(root, "project");
		const rust = agents.find((agent) => agent.name === "rust");
		expect(rust?.allowedSubagents).toEqual(["scout"]);
	});

	test("missing field leaves allowedSubagents undefined", () => {
		const root = tempProject();
		writeAgent(root, "rust", []);
		const { agents } = discoverAgents(root, "project");
		const rust = agents.find((agent) => agent.name === "rust");
		expect(rust?.allowedSubagents).toBeUndefined();
	});

	test("empty string yields empty list (preserves explicit opt-out)", () => {
		const root = tempProject();
		writeAgent(root, "rust", ["allowed-subagents: "]);
		const { agents } = discoverAgents(root, "project");
		const rust = agents.find((agent) => agent.name === "rust");
		expect(rust?.allowedSubagents).toEqual([]);
	});

	test("aliases (allowedSubagents / subagent-agents / subagent_agents) all parse", () => {
		const root = tempProject();
		writeAgent(root, "alpha", ["allowedSubagents: scout"]);
		writeAgent(root, "beta", ["subagent-agents: scout"]);
		writeAgent(root, "gamma", ["subagent_agents: scout"]);
		const { agents } = discoverAgents(root, "project");
		const get = (name: string) => agents.find((agent) => agent.name === name);
		expect(get("alpha")?.allowedSubagents).toEqual(["scout"]);
		expect(get("beta")?.allowedSubagents).toEqual(["scout"]);
		expect(get("gamma")?.allowedSubagents).toEqual(["scout"]);
	});
});
