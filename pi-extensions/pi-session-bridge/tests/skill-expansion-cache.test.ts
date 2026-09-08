import { describe, expect, test } from "bun:test";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import sessionBridge, { expandLoadedSlashContent, loadedSkillHashesBySession, type SlashCommandInfoLike } from "../extensions/session-bridge.ts";
import { fakePi, writeBridgeSettings } from "./lib/bridge-fixture.ts";
import { dir, p, useSlashFixture } from "./lib/slash-fixture.ts";

useSlashFixture();

describe("skill expansion cache", () => {
	test("dedups repeated skill expansion within the same session", () => {
		const skillPath = p("skills/orch/SKILL.md");
		mkdirSync(dirname(skillPath), { recursive: true });
		writeFileSync(skillPath, "---\nname: orch\n---\n# Orchestration\nStart work.\n");
		const commands = [{ name: "skill:orch", source: "skill", sourceInfo: { path: skillPath } }] as SlashCommandInfoLike[];
		const cache = new Map<string, Map<string, string>>();

		const first = expandLoadedSlashContent("/skill:orch start ABC-123", commands, readFileSync, {
			sessionId: "session-a",
			skillExpansionCache: cache,
		});
		expect(first.expanded).toBe(true);
		expect(first.text).toContain(`<skill name="orch" location="${skillPath}">`);
		expect(first.text).toContain("# Orchestration");

		const second = expandLoadedSlashContent("/skill:orch start\nABC-123\tready", commands, readFileSync, {
			sessionId: "session-a",
			skillExpansionCache: cache,
		});
		expect(second.expanded).toBe(true);
		expect(second.kind).toBe("skill");
		expect(second.text?.split("\n")[0]).toBe("skill_loaded=orch invocation=start ABC-123 ready");
		expect(second.text).not.toContain("<skill");
		expect(second.text).not.toContain("# Orchestration");

		const otherSession = expandLoadedSlashContent("/skill:orch start ABC-123", commands, readFileSync, {
			sessionId: "session-b",
			skillExpansionCache: cache,
		});
		expect(otherSession.text).toContain(`<skill name="orch" location="${skillPath}">`);
	});

	test("evicts only the shutting-down session from the skill expansion cache", async () => {
		writeBridgeSettings(dir);
		process.chdir(dir);
		process.env.PI_BRIDGE_DIR = p("bridge-dir");
		loadedSkillHashesBySession.set("session-a", new Map([["alpha", "hash-a"]]));
		loadedSkillHashesBySession.set("session-b", new Map([["beta", "hash-b"]]));

		const { pi, handlers } = fakePi();
		sessionBridge(pi);
		const shutdown = handlers.get("session_shutdown");
		expect(typeof shutdown).toBe("function");

		await shutdown?.({ reason: "quit" }, { sessionManager: { getSessionId: () => "session-a" } });

		expect(loadedSkillHashesBySession.has("session-a")).toBe(false);
		expect(loadedSkillHashesBySession.get("session-b")?.get("beta")).toBe("hash-b");
	});

	test("bounds skill expansion cache to the 100 most recent sessions", () => {
		const skillPath = p("skills/orch/SKILL.md");
		mkdirSync(dirname(skillPath), { recursive: true });
		writeFileSync(skillPath, "---\nname: orch\n---\n# Orchestration\nStart work.\n");
		const commands = [{ name: "skill:orch", source: "skill", sourceInfo: { path: skillPath } }] as SlashCommandInfoLike[];
		const cache = new Map<string, Map<string, string>>();

		for (let index = 0; index < 101; index++) {
			expandLoadedSlashContent("/skill:orch start ABC-123", commands, readFileSync, {
				sessionId: `session-${index}`,
				skillExpansionCache: cache,
			});
		}

		expect(cache.size).toBe(100);
		expect(cache.has("session-0")).toBe(false);
		expect(cache.has("session-1")).toBe(true);
		expect(cache.has("session-100")).toBe(true);
	});

	test("re-expands skill after SKILL.md content changes", () => {
		const skillPath = p("skills/orch/SKILL.md");
		mkdirSync(dirname(skillPath), { recursive: true });
		writeFileSync(skillPath, "---\nname: orch\n---\n# Orchestration v1\n");
		const commands = [{ name: "skill:orch", source: "skill", sourceInfo: { path: skillPath } }] as SlashCommandInfoLike[];
		const cache = new Map<string, Map<string, string>>();

		const first = expandLoadedSlashContent("/skill:orch run", commands, readFileSync, {
			sessionId: "session-a",
			skillExpansionCache: cache,
		});
		expect(first.text).toContain("# Orchestration v1");

		const deduped = expandLoadedSlashContent("/skill:orch run", commands, readFileSync, {
			sessionId: "session-a",
			skillExpansionCache: cache,
		});
		expect(deduped.text?.split("\n")[0]).toBe("skill_loaded=orch invocation=run");

		writeFileSync(skillPath, "---\nname: orch\n---\n# Orchestration v2\n");
		const changed = expandLoadedSlashContent("/skill:orch run", commands, readFileSync, {
			sessionId: "session-a",
			skillExpansionCache: cache,
		});
		expect(changed.text).toContain(`<skill name="orch" location="${skillPath}">`);
		expect(changed.text).toContain("# Orchestration v2");
		expect(changed.text).not.toContain("# Orchestration v1");

		const dedupedAgain = expandLoadedSlashContent("/skill:orch run", commands, readFileSync, {
			sessionId: "session-a",
			skillExpansionCache: cache,
		});
		expect(dedupedAgain.text?.split("\n")[0]).toBe("skill_loaded=orch invocation=run");
	});

	test("dedup is independent per skill within a session (pins Map<sessionId, Map<skillName, hash>>)", () => {
		const alphaPath = p("skills/alpha/SKILL.md");
		const betaPath = p("skills/beta/SKILL.md");
		mkdirSync(dirname(alphaPath), { recursive: true });
		mkdirSync(dirname(betaPath), { recursive: true });
		writeFileSync(alphaPath, "---\nname: alpha\n---\n# Alpha Skill\nA body.\n");
		writeFileSync(betaPath, "---\nname: beta\n---\n# Beta Skill\nB body.\n");
		const commands = [
			{ name: "skill:alpha", source: "skill", sourceInfo: { path: alphaPath } },
			{ name: "skill:beta", source: "skill", sourceInfo: { path: betaPath } },
		] as SlashCommandInfoLike[];
		const cache = new Map<string, Map<string, string>>();
		const options = { sessionId: "session-a", skillExpansionCache: cache };

		const firstAlpha = expandLoadedSlashContent("/skill:alpha run-a", commands, readFileSync, options);
		expect(firstAlpha.text).toContain(`<skill name="alpha" location="${alphaPath}">`);
		expect(firstAlpha.text).toContain("# Alpha Skill");

		// Skill B in the same session must still get the FULL body, not the dedup reminder.
		const firstBeta = expandLoadedSlashContent("/skill:beta run-b", commands, readFileSync, options);
		expect(firstBeta.text).toContain(`<skill name="beta" location="${betaPath}">`);
		expect(firstBeta.text).toContain("# Beta Skill");
		expect(firstBeta.text).not.toContain("skill_loaded=");

		// Re-expanding each skill independently now hits the short reminder for each.
		const secondAlpha = expandLoadedSlashContent("/skill:alpha run-a", commands, readFileSync, options);
		expect(secondAlpha.text?.split("\n")[0]).toBe("skill_loaded=alpha invocation=run-a");

		const secondBeta = expandLoadedSlashContent("/skill:beta run-b", commands, readFileSync, options);
		expect(secondBeta.text?.split("\n")[0]).toBe("skill_loaded=beta invocation=run-b");
	});
});
