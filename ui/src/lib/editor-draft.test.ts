import { describe, expect, it } from "vitest";
import { MANIFEST_SCHEMA } from "@/bindings";
import {
  addCustomHook,
  type Draft,
  EMPTY_FRONTMATTER,
  emptyDraft,
  emptyHook,
  formatHookAgents,
  parseHookAgents,
  parseList,
  removeCustomHook,
  setAgentSkill,
  setCustomHook,
  setFrontmatterField,
  setInstruction,
  toDraft,
} from "./editor-draft";

function draft(overrides: Partial<Draft> = {}): Draft {
  return { ...emptyDraft(), ...overrides };
}

describe("emptyDraft", () => {
  // The backend validates this draft before anything stamps a schema on
  // it, so a literal here is a first save on a scope with no kendex.toml
  // refused by our own validator. The number comes from the same constant
  // the writer uses; nothing in this file may hard-code one.
  it("carries the schema this build writes", () => {
    expect(emptyDraft().schema).toBe(MANIFEST_SCHEMA);
  });
});

describe("toDraft", () => {
  it("fills the keys the write shape requires without inventing values", () => {
    const widened = toDraft({
      schema: 1,
      install: {},
      sources: { kendex: { repo: "owner/repo", enabled: true } },
      agents: { orch: { source: "kendex", enabled: true } },
      "agent-frontmatter": { claude: { orch: { model: "opus" } } },
      "custom-hooks": [
        { event: "PreToolUse", command: "./g.sh", agents: "all" },
      ],
    });

    expect(widened.sources?.kendex).toEqual({
      repo: "owner/repo",
      path: null,
      rev: null,
      enabled: true,
    });
    expect(widened.agents?.orch.harnesses).toBeNull();
    expect(widened["agent-frontmatter"]?.claude.orch).toMatchObject({
      model: "opus",
      color: null,
      "deny-tools": null,
    });
    expect(widened["custom-hooks"]?.[0]).toMatchObject({
      matcher: null,
      description: null,
    });
  });
});

describe("setAgentSkill", () => {
  it("creates a row on the first check and keeps it sorted", () => {
    const next = setAgentSkill(
      setAgentSkill(draft(), "orch", "review", true),
      "orch",
      "github",
      true,
    );
    expect(next["agent-skills"]).toEqual({ orch: ["github", "review"] });
  });

  it("keeps an emptied row so the removal stays durable", () => {
    const seeded = setAgentSkill(draft(), "orch", "github", true);
    expect(
      setAgentSkill(seeded, "orch", "github", false)["agent-skills"],
    ).toEqual({
      orch: [],
    });
  });

  it("ignores unchecking an agent that has no row", () => {
    const base = draft();
    expect(setAgentSkill(base, "orch", "github", false)).toBe(base);
  });
});

describe("setInstruction", () => {
  it("writes an entry and drops the table once the last one goes", () => {
    const withText = setInstruction(
      draft(),
      "agent-launch-instructions",
      "all",
      "read the plan",
    );
    expect(withText["agent-launch-instructions"]).toEqual({
      all: "read the plan",
    });
    const cleared = setInstruction(
      withText,
      "agent-launch-instructions",
      "all",
      null,
    );
    expect(cleared["agent-launch-instructions"]).toBeUndefined();
  });

  it("keeps sibling entries when one is removed", () => {
    let next = setInstruction(draft(), "skill-instructions", "all", "shared");
    next = setInstruction(next, "skill-instructions", "github", "use gh");
    next = setInstruction(next, "skill-instructions", "all", null);
    expect(next["skill-instructions"]).toEqual({ github: "use gh" });
  });
});

describe("setFrontmatterField", () => {
  it("sets a field under harness and agent", () => {
    const next = setFrontmatterField(
      draft(),
      "claude",
      "orch",
      "model",
      "opus",
    );
    expect(next["agent-frontmatter"]?.claude.orch).toEqual({
      ...EMPTY_FRONTMATTER,
      model: "opus",
    });
  });

  it("prunes agent, harness, and table when the last value is cleared", () => {
    const set = setFrontmatterField(draft(), "claude", "orch", "model", "opus");
    const cleared = setFrontmatterField(set, "claude", "orch", "model", null);
    expect(cleared["agent-frontmatter"]).toBeUndefined();
  });

  it("prunes an emptied list but keeps other fields", () => {
    let next = setFrontmatterField(draft(), "pi", "orch", "pane", true);
    next = setFrontmatterField(next, "pi", "orch", "deny-tools", null);
    expect(next["agent-frontmatter"]?.pi.orch.pane).toBe(true);
  });
});

describe("custom hooks", () => {
  it("adds, edits, and removes entries", () => {
    const added = addCustomHook(draft(), {
      ...emptyHook(),
      event: "PreToolUse",
      command: "./guard.sh",
    });
    const edited = setCustomHook(added, 0, {
      ...emptyHook(),
      event: "PreToolUse",
      command: "./guard.sh",
      matcher: "Bash",
    });
    expect(edited["custom-hooks"]?.[0].matcher).toBe("Bash");
    expect(removeCustomHook(edited, 0)["custom-hooks"]).toBeUndefined();
  });

  it("refuses to edit an index that does not exist", () => {
    expect(() => setCustomHook(draft(), 0, emptyHook())).toThrow(RangeError);
  });
});

describe("field parsing", () => {
  it("round-trips comma lists and hook agents", () => {
    expect(parseList(" a , b ,, ")).toEqual(["a", "b"]);
    expect(parseList("   ")).toBeNull();
    expect(parseHookAgents("engineer")).toBe("engineer");
    expect(parseHookAgents("orch, review")).toEqual(["orch", "review"]);
    expect(formatHookAgents(["orch", "review"])).toBe("orch, review");
    expect(formatHookAgents(undefined)).toBe("");
  });
});
