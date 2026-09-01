import { describe, expect, it } from "vitest";
import type { DriftRow } from "@/bindings";
import { abbreviateHome, mergeDriftRows, summarizePaths } from "./drift-merge";

const GLOBAL = { scope: "global" } as const;

function row(overrides: Partial<DriftRow>): DriftRow {
  return {
    kind: "skill",
    name: "agent-browser",
    harness: "claude",
    scope: GLOBAL,
    state: "unmanaged",
    detail: "/home/method/.claude/skills/agent-browser",
    ...overrides,
  };
}

describe("mergeDriftRows", () => {
  it("folds rows sharing kind, name, and state into one", () => {
    const merged = mergeDriftRows([
      row({ harness: "claude" }),
      row({
        harness: "pi",
        detail: "/home/method/.pi/agent/skills/agent-browser",
      }),
    ]);
    expect(merged).toHaveLength(1);
    expect(merged[0].installations).toHaveLength(2);
  });

  it("keeps rows with different names or states apart", () => {
    const merged = mergeDriftRows([
      row({ name: "journal", harness: "claude" }),
      row({ name: "agent-browser", harness: "pi" }),
      row({ name: "agent-browser", harness: "claude", state: "stale" }),
    ]);
    expect(merged).toHaveLength(3);
  });

  it("preserves installation order within a group", () => {
    const merged = mergeDriftRows([
      row({ harness: "claude" }),
      row({ harness: "pi" }),
    ]);
    expect(merged[0].installations.map((r) => r.harness)).toEqual([
      "claude",
      "pi",
    ]);
  });
});

describe("abbreviateHome", () => {
  it("shortens a home directory path to ~", () => {
    expect(abbreviateHome("/home/method/.claude/skills/agent-browser")).toBe(
      "~/.claude/skills/agent-browser",
    );
    expect(abbreviateHome("/Users/dana/.codex/skills/deploy")).toBe(
      "~/.codex/skills/deploy",
    );
  });

  it("leaves paths outside the home directory alone", () => {
    expect(abbreviateHome("/etc/kendex/config.json")).toBe(
      "/etc/kendex/config.json",
    );
  });
});

describe("summarizePaths", () => {
  it("joins two paths, abbreviated, with the full paths in the title", () => {
    const summary = summarizePaths([
      "/home/method/.claude/skills/agent-browser",
      "/home/method/.pi/agent/skills/agent-browser",
    ]);
    expect(summary?.text).toBe(
      "~/.claude/skills/agent-browser · ~/.pi/agent/skills/agent-browser",
    );
    expect(summary?.title).toBe(
      "/home/method/.claude/skills/agent-browser\n/home/method/.pi/agent/skills/agent-browser",
    );
  });

  it("collapses three or more paths to the first plus a count", () => {
    const summary = summarizePaths([
      "/home/method/.claude/skills/x",
      "/home/method/.codex/skills/x",
      "/home/method/.pi/agent/skills/x",
    ]);
    expect(summary?.text).toBe("~/.claude/skills/x +2 more");
  });

  it("counts one place once however many tools read it", () => {
    const shared = "/home/method/hand-made/skills/browser";
    const summary = summarizePaths([shared, shared]);
    expect(summary?.text).toBe("~/hand-made/skills/browser");
    expect(summary?.count).toBe(1);
  });

  it("returns null with no paths", () => {
    expect(summarizePaths([null])).toBeNull();
  });
});
