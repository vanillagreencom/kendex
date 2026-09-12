import { describe, expect, it } from "vitest";
import type { Scope } from "@/bindings";
import { scopeChoices } from "./derive";

/** The places a set of rows stands in, as the table hands them over. */
const places = (roots: string[]): Scope[] =>
  roots.map((root) => ({ scope: "project", root }));

describe("scopeChoices", () => {
  it("sorts distinct project roots the rows stand in, and the selected one", () => {
    const rows: {
      name: string;
      places: Scope[];
      selection: Parameters<typeof scopeChoices>[1];
      expected: string[];
    }[] = [
      {
        name: "roots the rows stand in",
        places: places(["/b", "/a", "/a"]),
        selection: "all",
        expected: ["/a", "/b"],
      },
      {
        name: "selected empty project",
        places: places(["/z"]),
        selection: { project: "/empty" },
        expected: ["/empty", "/z"],
      },
      {
        name: "selected before any row",
        places: [],
        selection: { project: "/empty" },
        expected: ["/empty"],
      },
      {
        name: "selected project the rows stand in",
        places: places(["/a"]),
        selection: { project: "/a" },
        expected: ["/a"],
      },
      // The personal setup is not a project and has a pill of its own.
      {
        name: "the personal setup",
        places: [{ scope: "global" }, ...places(["/a"])],
        selection: "all",
        expected: ["/a"],
      },
    ];
    expect(rows.length, "scope choice table is empty").toBeGreaterThan(0);
    for (const row of rows)
      expect(scopeChoices(row.places, row.selection), row.name).toEqual(
        row.expected,
      );
  });
});
