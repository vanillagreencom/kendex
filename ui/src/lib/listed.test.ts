import { describe, expect, it } from "vitest";
import { listed } from "./listed";

// One rule, read by every surface that lists things — the places a package
// is customized in, the kinds a catalog holds. The three-or-more form is
// where the no-serial-comma rule actually lives, and it is the ordinary
// case for a catalog offering more than two kinds.
describe("naming things in a line", () => {
  it("says one name alone", () => {
    expect(listed(["42 skills"])).toBe("42 skills");
  });

  it("joins two with and, no comma", () => {
    expect(listed(["42 skills", "1 agent"])).toBe("42 skills and 1 agent");
  });

  it("puts no comma before the and", () => {
    expect(listed(["42 skills", "1 agent", "3 commands"])).toBe(
      "42 skills, 1 agent and 3 commands",
    );
  });

  it("uses one and however long the list runs", () => {
    expect(listed(["a", "b", "c", "d"])).toBe("a, b, c and d");
  });
});
