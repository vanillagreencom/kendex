import { describe, expect, it } from "vitest";
import type { HookDelivery } from "@/bindings";
import { customizedLine, hookDeliverySummary } from "@/lib/copy-customize";
import type { ItemCustomization } from "@/lib/customization";

// The line under a hook is built from delivery rows the engine computed —
// these tests pin the composition, so no string literal in the UI can
// claim an enforcement the engine didn't decide.
describe("hookDeliverySummary", () => {
  const row = (
    harness: HookDelivery["harness"],
    mode: HookDelivery["mode"],
  ): HookDelivery => ({ harness, mode, note: null });

  it("says where a hook runs and where it is only guidance", () => {
    const line = hookDeliverySummary([
      row("claude", "runs"),
      row("codex", "runs"),
      row("cursor", "instructions"),
    ]);
    expect(line).toBe(
      "Runs in Claude Code and Codex · guidance only in Cursor — nothing enforces it there",
    );
  });

  it("counts Claude's per-agent block as running", () => {
    expect(hookDeliverySummary([row("claude", "runs-in-agent-file")])).toBe(
      "Runs in Claude Code",
    );
  });

  it("names the harnesses a hook cannot run in at all", () => {
    expect(hookDeliverySummary([row("cursor", "unavailable")])).toBe(
      "Can't run in Cursor",
    );
  });

  it("says nothing for an empty set", () => {
    expect(hookDeliverySummary([])).toBe("");
  });
});

describe("customizedLine", () => {
  const nothing: ItemCustomization = {
    launch: null,
    additional: null,
    instructions: null,
    skills: null,
    frontmatter: [],
  };

  const facts = (edited: boolean, forked: boolean, values = false) => ({
    edited,
    forked,
    values,
  });

  it("names a hand edit on its own", () => {
    expect(customizedLine(facts(true, false), nothing)).toBe("Edited by you");
  });

  it("names a fork and the settings set on top of it", () => {
    expect(
      customizedLine(facts(false, true), { ...nothing, instructions: "x" }),
    ).toBe("Forked · Extra instructions");
  });

  it("names a fork edited since, then its settings", () => {
    expect(customizedLine(facts(true, true), { ...nothing, launch: "x" })).toBe(
      "Forked · Edited by you · Launch instructions",
    );
  });

  it("lists only the settings for a settings row", () => {
    expect(
      customizedLine(facts(false, false), { ...nothing, launch: "x" }),
    ).toBe("Launch instructions");
  });

  /// A package settings value is a customization of its own: a skill
  /// nothing in the manifest touches still belongs on the index when
  /// this place's settings file answers one of its keys off the default.
  it("names non-default settings values on their own", () => {
    expect(customizedLine(facts(false, false, true), nothing)).toBe(
      "Non-default settings",
    );
  });
});

// The hook line lists harnesses, so it reads as the same writer as every
// other list in the app: the `and` goes in front of the last one.
describe("what a hook's delivery line says about three harnesses", () => {
  it("joins them the way the rest of the app joins a list", () => {
    const line = hookDeliverySummary([
      { harness: "claude", mode: "runs" },
      { harness: "codex", mode: "runs" },
      { harness: "cursor", mode: "runs" },
    ] as Parameters<typeof hookDeliverySummary>[0]);
    expect(line).toContain("Claude Code, Codex and Cursor");
    expect(line).not.toContain("Codex, Cursor");
  });
});
