import { describe, expect, it } from "vitest";
import type { HookEvent } from "@/bindings";
import { matchingEvents } from "./hook-events";

const EVENTS: HookEvent[] = [
  { name: "PreToolUse", fires: "Before the agent runs a tool" },
  { name: "PostToolUse", fires: "After a tool returns" },
  { name: "SessionStart", fires: "A session starts" },
];

describe("matchingEvents", () => {
  it("finds events by name or description", () => {
    const rows = [
      {
        name: "blank query",
        query: "  ",
        expected: ["PreToolUse", "PostToolUse", "SessionStart"],
      },
      {
        name: "case-insensitive name",
        query: "pretool",
        expected: ["PreToolUse"],
      },
      { name: "session", query: "session", expected: ["SessionStart"] },
      {
        name: "description only",
        query: "runs a tool",
        expected: ["PreToolUse"],
      },
      { name: "no match", query: "webhook", expected: [] },
    ];
    expect(rows.length, "hook event query table is empty").toBeGreaterThan(0);
    for (const row of rows)
      expect(
        matchingEvents(EVENTS, row.query).map((event) => event.name),
        row.name,
      ).toEqual(row.expected);
  });
});
