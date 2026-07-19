/**
 * Tests for isolated mode (CLAUDE_BRIDGE_ISOLATED=1) and the piUserDir routing
 * of paths that previously hardcoded ~/.pi/agent.
 *
 * Isolated mode is the contract for host apps that embed the bridge and own
 * every config dir explicitly (PI_CODING_AGENT_DIR + CLAUDE_CONFIG_DIR): no
 * cwd-ancestor discovery, no $PATH executable fallback, nothing read from the
 * real home directory. Default (unset) behavior must be byte-identical to the
 * pre-isolation bridge.
 */
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { isolatedFromEnv, loadConfig, piUserDir, recordProjectTrust } from "../src/config.ts";
import { resolveAgentsMdPath } from "../src/agents-md.ts";
import { readAppendSystemPromptFiles } from "../src/prompt-context.ts";
import { resolveClaudeExecutable } from "../src/index.ts";

const ENV_KEYS = ["CLAUDE_BRIDGE_ISOLATED", "PI_CODING_AGENT_DIR", "PATH"];

function withEnv(overrides, fn) {
	const saved = new Map(ENV_KEYS.map((key) => [key, process.env[key]]));
	try {
		for (const [key, value] of Object.entries(overrides)) {
			if (value === undefined) delete process.env[key];
			else process.env[key] = value;
		}
		return fn();
	} finally {
		for (const [key, value] of saved) {
			if (value === undefined) delete process.env[key];
			else process.env[key] = value;
		}
	}
}

function withTempDir(fn) {
	const dir = mkdtempSync(join(tmpdir(), "claude-bridge-isolation-"));
	try {
		return fn(dir);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
}

describe("isolatedFromEnv", () => {
	it("is off when unset, empty, or falsy", () => {
		for (const value of [undefined, "", "0", "false", "off", "no", "nonsense"]) {
			withEnv({ CLAUDE_BRIDGE_ISOLATED: value }, () => {
				assert.equal(isolatedFromEnv(), false, `value: ${value}`);
			});
		}
	});

	it("accepts the same truthy spellings as the connector flag", () => {
		for (const value of ["1", "true", "yes", "on", " TRUE ", "Yes"]) {
			withEnv({ CLAUDE_BRIDGE_ISOLATED: value }, () => {
				assert.equal(isolatedFromEnv(), true, `value: ${value}`);
			});
		}
	});
});

describe("piUserDir", () => {
	it("defaults to ~/.pi/agent when PI_CODING_AGENT_DIR is unset (no-behavior-change proof)", () => {
		withEnv({ PI_CODING_AGENT_DIR: undefined }, () => {
			assert.equal(piUserDir(), resolve(join(homedir(), ".pi", "agent")));
		});
	});

	it("resolves PI_CODING_AGENT_DIR when set", () => withTempDir((dir) => {
		withEnv({ PI_CODING_AGENT_DIR: dir }, () => {
			assert.equal(piUserDir(), resolve(dir));
		});
	}));
});

describe("resolveAgentsMdPath isolation", () => {
	it("default mode still finds AGENTS.md in cwd parents", () => withTempDir((dir) => {
		const cwdDir = join(dir, "cwd");
		mkdirSync(cwdDir, { recursive: true });
		writeFileSync(join(cwdDir, "AGENTS.md"), "# personal instructions\n");
		const oldCwd = process.cwd();
		try {
			process.chdir(cwdDir);
			withEnv({ CLAUDE_BRIDGE_ISOLATED: undefined }, () => {
				assert.equal(resolveAgentsMdPath(), join(process.cwd(), "AGENTS.md"));
			});
		} finally {
			process.chdir(oldCwd);
		}
	}));

	it("isolated mode ignores cwd AGENTS.md and reads only piUserDir", () => withTempDir((dir) => {
		const cwdDir = join(dir, "cwd");
		const agentDir = join(dir, "agent");
		mkdirSync(cwdDir, { recursive: true });
		mkdirSync(agentDir, { recursive: true });
		writeFileSync(join(cwdDir, "AGENTS.md"), "# personal instructions\n");
		const oldCwd = process.cwd();
		try {
			process.chdir(cwdDir);
			withEnv({ CLAUDE_BRIDGE_ISOLATED: "1", PI_CODING_AGENT_DIR: agentDir }, () => {
				// No app-owned AGENTS.md → nothing at all (cwd file must NOT leak).
				assert.equal(resolveAgentsMdPath(), undefined);
				// App-owned AGENTS.md wins once present.
				writeFileSync(join(agentDir, "AGENTS.md"), "# app instructions\n");
				assert.equal(resolveAgentsMdPath(), resolve(join(agentDir, "AGENTS.md")));
			});
		} finally {
			process.chdir(oldCwd);
		}
	}));
});

describe("loadConfig isolation", () => {
	it("isolated mode ignores trusted project config and reads only piUserDir", () => withTempDir((dir) => {
		const agentDir = join(dir, "agent");
		const project = join(dir, "project");
		mkdirSync(agentDir, { recursive: true });
		mkdirSync(join(project, ".pi"), { recursive: true });
		writeFileSync(join(agentDir, "claude-bridge.json"), JSON.stringify({ provider: { fastMode: false } }));
		writeFileSync(join(project, ".pi", "claude-bridge.json"), JSON.stringify({ provider: { fastMode: true, pathToClaudeCodeExecutable: "/opt/evil/claude" } }));
		writeFileSync(join(project, ".pi", "settings.json"), JSON.stringify({
			vstack: { extensionManager: { config: { "@vanillagreen/pi-claude-bridge": { pathToClaudeCodeExecutable: "/opt/evil/claude2" } } } },
		}));
		withEnv({ PI_CODING_AGENT_DIR: agentDir }, () => {
			recordProjectTrust({ cwd: project, isProjectTrusted: () => true });
			// Sanity: default mode DOES read the trusted project config.
			withEnv({ CLAUDE_BRIDGE_ISOLATED: undefined }, () => {
				const config = loadConfig(project);
				assert.equal(config.provider?.fastMode, true);
			});
			// Isolated mode ignores both project files even though trust is recorded.
			withEnv({ CLAUDE_BRIDGE_ISOLATED: "1" }, () => {
				const config = loadConfig(project);
				assert.equal(config.provider?.fastMode, false);
				assert.equal(config.provider?.pathToClaudeCodeExecutable, undefined);
			});
		});
	}));
});

describe("readAppendSystemPromptFiles isolation", () => {
	it("isolated mode skips project .pi/APPEND_SYSTEM.md but keeps the piUserDir file", () => withTempDir((dir) => {
		const agentDir = join(dir, "agent");
		const project = join(dir, "project");
		mkdirSync(agentDir, { recursive: true });
		mkdirSync(join(project, ".pi"), { recursive: true });
		writeFileSync(join(agentDir, "APPEND_SYSTEM.md"), "global extra\n");
		writeFileSync(join(project, ".pi", "APPEND_SYSTEM.md"), "project extra\n");
		withEnv({ PI_CODING_AGENT_DIR: agentDir }, () => {
			withEnv({ CLAUDE_BRIDGE_ISOLATED: undefined }, () => {
				const labels = readAppendSystemPromptFiles(project).map((file) => file.label);
				assert.deepEqual(labels, ["global APPEND_SYSTEM.md", "project .pi/APPEND_SYSTEM.md"]);
			});
			withEnv({ CLAUDE_BRIDGE_ISOLATED: "1" }, () => {
				const files = readAppendSystemPromptFiles(project);
				assert.deepEqual(files.map((file) => file.label), ["global APPEND_SYSTEM.md"]);
				assert.equal(files[0].content, "global extra");
			});
		});
	}));
});

describe("resolveClaudeExecutable isolation", () => {
	it("a configured path always wins", () => {
		withEnv({ CLAUDE_BRIDGE_ISOLATED: "1" }, () => {
			assert.equal(resolveClaudeExecutable("/opt/app/bin/claude"), "/opt/app/bin/claude");
		});
	});

	it("default mode falls back to $PATH; isolated mode never does", () => withTempDir((dir) => {
		const bin = join(dir, "bin");
		mkdirSync(bin, { recursive: true });
		const fakeClaude = join(bin, "claude");
		writeFileSync(fakeClaude, "#!/bin/sh\nexit 0\n");
		chmodSync(fakeClaude, 0o755);
		withEnv({ PATH: bin }, () => {
			withEnv({ CLAUDE_BRIDGE_ISOLATED: undefined }, () => {
				assert.equal(resolveClaudeExecutable(undefined), fakeClaude);
			});
			withEnv({ CLAUDE_BRIDGE_ISOLATED: "1" }, () => {
				assert.equal(resolveClaudeExecutable(undefined), undefined);
			});
		});
	}));
});
