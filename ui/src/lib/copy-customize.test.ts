import { describe, expect, it } from "vitest";
import type { HookDelivery } from "@/bindings";
import { customizedLine, hookDeliverySummary } from "@/lib/copy-customize";
import type { ItemCustomization } from "@/lib/customization";

describe("hookDeliverySummary", () => {
  const row = (
    harness: HookDelivery["harness"],
    mode: HookDelivery["mode"],
  ): HookDelivery => ({ harness, mode, note: null });

  it("composes the engine's delivery modes for their named harnesses", () => {
    const rows = [
      {
        name: "execution and guidance",
        deliveries: [
          row("claude", "runs"),
          row("codex", "runs"),
          row("cursor", "instructions"),
        ],
        expected:
          "Runs in Claude Code and Codex · guidance only in Cursor — nothing enforces it there",
      },
      {
        name: "agent-file execution",
        deliveries: [row("claude", "runs-in-agent-file")],
        expected: "Runs in Claude Code",
      },
      {
        name: "unavailable",
        deliveries: [row("cursor", "unavailable")],
        expected: "Can't run in Cursor",
      },
      { name: "empty", deliveries: [], expected: "" },
    ];
    expect(rows.length, "hook delivery summary table is empty").toBeGreaterThan(
      0,
    );
    for (const entry of rows)
      expect(hookDeliverySummary(entry.deliveries), entry.name).toBe(
        entry.expected,
      );
  });

  it("joins three harness names with the final conjunction", () => {
    const line = hookDeliverySummary([
      { harness: "claude", mode: "runs" },
      { harness: "codex", mode: "runs" },
      { harness: "cursor", mode: "runs" },
    ] as Parameters<typeof hookDeliverySummary>[0]);
    expect(line).toContain("Claude Code, Codex and Cursor");
    expect(line).not.toContain("Codex, Cursor");
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

  it("lists the customization facts and settings held by the package", () => {
    const rows = [
      {
        name: "hand edit",
        facts: facts(true, false),
        settings: nothing,
        expected: "Edited by you",
      },
      {
        name: "fork and settings",
        facts: facts(false, true),
        settings: { ...nothing, instructions: "x" },
        expected: "Forked · Extra instructions",
      },
      {
        name: "edited fork and settings",
        facts: facts(true, true),
        settings: { ...nothing, launch: "x" },
        expected: "Forked · Edited by you · Launch instructions",
      },
      {
        name: "settings only",
        facts: facts(false, false),
        settings: { ...nothing, launch: "x" },
        expected: "Launch instructions",
      },
      {
        name: "non-default values",
        facts: facts(false, false, true),
        settings: nothing,
        expected: "Non-default settings",
      },
    ];
    expect(rows.length, "customization summary table is empty").toBeGreaterThan(
      0,
    );
    for (const row of rows)
      expect(customizedLine(row.facts, row.settings), row.name).toBe(
        row.expected,
      );
  });
});
