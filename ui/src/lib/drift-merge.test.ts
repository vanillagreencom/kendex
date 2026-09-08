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
  it("groups only equal item states and preserves installation order", () => {
    const rows = [
      {
        name: "matching item states",
        input: [
          row({ harness: "claude" }),
          row({
            harness: "pi",
            detail: "/home/method/.pi/agent/skills/agent-browser",
          }),
        ],
        expected: [{ installations: [{}, {}] }],
      },
      {
        name: "different names or states",
        input: [
          row({ name: "journal", harness: "claude" }),
          row({ name: "agent-browser", harness: "pi" }),
          row({ name: "agent-browser", harness: "claude", state: "stale" }),
        ],
        expected: [{}, {}, {}],
      },
      {
        name: "installation order",
        input: [row({ harness: "claude" }), row({ harness: "pi" })],
        expected: [
          { installations: [{ harness: "claude" }, { harness: "pi" }] },
        ],
      },
    ];
    expect(rows.length, "drift grouping table is empty").toBeGreaterThan(0);
    for (const row of rows)
      expect(mergeDriftRows(row.input), row.name).toMatchObject(row.expected);
  });
});

describe("abbreviateHome", () => {
  it("shortens home roots and preserves other paths", () => {
    const rows = [
      {
        path: "/home/method/.claude/skills/agent-browser",
        expected: "~/.claude/skills/agent-browser",
      },
      {
        path: "/Users/dana/.codex/skills/deploy",
        expected: "~/.codex/skills/deploy",
      },
      { path: "/etc/kendex/config.json", expected: "/etc/kendex/config.json" },
    ];
    expect(rows.length, "home path table is empty").toBeGreaterThan(0);
    for (const row of rows)
      expect(abbreviateHome(row.path), row.path).toBe(row.expected);
  });
});

describe("summarizePaths", () => {
  it("summarizes unique paths while retaining their original titles", () => {
    const shared = "/home/method/hand-made/skills/browser";
    const rows = [
      {
        name: "two paths",
        paths: [
          "/home/method/.claude/skills/agent-browser",
          "/home/method/.pi/agent/skills/agent-browser",
        ],
        expected: {
          text: "~/.claude/skills/agent-browser · ~/.pi/agent/skills/agent-browser",
          title:
            "/home/method/.claude/skills/agent-browser\n/home/method/.pi/agent/skills/agent-browser",
        },
      },
      {
        name: "collapsed paths",
        paths: [
          "/home/method/.claude/skills/x",
          "/home/method/.codex/skills/x",
          "/home/method/.pi/agent/skills/x",
        ],
        expected: { text: "~/.claude/skills/x +2 more" },
      },
      {
        name: "shared path",
        paths: [shared, shared],
        expected: { text: "~/hand-made/skills/browser", count: 1 },
      },
    ];
    expect(rows.length, "path summary table is empty").toBeGreaterThan(0);
    for (const row of rows)
      expect(summarizePaths(row.paths), row.name).toMatchObject(row.expected);
  });

  it("returns null with no paths", () => {
    expect(summarizePaths([null])).toBeNull();
  });
});
