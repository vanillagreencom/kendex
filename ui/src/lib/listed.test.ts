import { describe, expect, it } from "vitest";
import { listed } from "./listed";

describe("listed", () => {
  it("joins each list with one final conjunction", () => {
    const rows = [
      { name: "one", names: ["42 skills"], expected: "42 skills" },
      {
        name: "two",
        names: ["42 skills", "1 agent"],
        expected: "42 skills and 1 agent",
      },
      {
        name: "three",
        names: ["42 skills", "1 agent", "3 commands"],
        expected: "42 skills, 1 agent and 3 commands",
      },
      { name: "four", names: ["a", "b", "c", "d"], expected: "a, b, c and d" },
    ];
    expect(rows.length, "list formatting table is empty").toBeGreaterThan(0);
    for (const row of rows)
      expect(listed(row.names), row.name).toBe(row.expected);
  });
});
