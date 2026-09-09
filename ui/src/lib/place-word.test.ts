import { describe, expect, it } from "vitest";
import type { Scope } from "@/bindings";
import { placeWord } from "@/lib/place-word";

const project = (root: string): Scope => ({ scope: "project", root });
const PERSONAL: Scope = { scope: "global" };

// The personal setup is not a project. A set counted as projects while it
// holds the personal setup names a kind of place that holds nothing, and
// the list behind the count says so.
describe("what a counted set of places is called", () => {
  it("calls a set projects only when every place in it is one", () => {
    const rows = [
      { name: "one project", scopes: [project("/w/alpha")], word: "project" },
      {
        name: "two projects",
        scopes: [project("/w/alpha"), project("/w/beta")],
        word: "projects",
      },
      { name: "the personal setup alone", scopes: [PERSONAL], word: "place" },
      {
        name: "the personal setup and a project",
        scopes: [PERSONAL, project("/w/alpha")],
        word: "places",
      },
    ];
    expect(rows).toHaveLength(4);
    for (const row of rows)
      expect(placeWord(row.scopes), row.name).toBe(row.word);
  });

  // A mark reading "1 of 3 places" names three places and agrees with
  // three, so the noun's number is the caller's to state where it differs
  // from the set's own size.
  it("agrees with a count the caller states instead of the set's size", () => {
    expect(placeWord([project("/w/alpha"), project("/w/beta")], 1)).toBe(
      "project",
    );
  });
});
