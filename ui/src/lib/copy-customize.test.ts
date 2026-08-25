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

  const facts = (edited: boolean, forked: boolean) => ({ edited, forked });

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
});
