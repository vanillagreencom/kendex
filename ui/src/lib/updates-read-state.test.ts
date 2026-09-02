import { describe, expect, it } from "vitest";
import { updateRow } from "@/components/updates-test-rows";
import { packageRequiredBy } from "./updates-read-state";

const PROJECT = { scope: "project" as const, root: "/work/app" };
const OTHER = { scope: "project" as const, root: "/work/other" };

const row = (requiredBy: string[]) =>
  updateRow("gh", PROJECT.root, { derived: true, requiredBy });

const place = (scope = PROJECT) => ({
  kind: "skill" as const,
  name: "gh",
  scope,
});

/** Which packages required the one a place names. Read through a store
 *  selector on every render of the package page, so the no-answer case has
 *  to be a stable value as well as an empty one. */
describe("packageRequiredBy", () => {
  it("names every package the matching row records", () => {
    expect(
      packageRequiredBy({ rows: [row(["dev", "orch"])] }, place()),
    ).toEqual(["dev", "orch"]);
  });

  it("reads no other place's row", () => {
    expect(packageRequiredBy({ rows: [row(["dev"])] }, place(OTHER))).toEqual(
      [],
    );
  });

  it("says nothing where no row speaks for the place", () => {
    expect(packageRequiredBy({ rows: [] }, place())).toEqual([]);
  });

  it("says nothing for no place at all", () => {
    expect(packageRequiredBy({ rows: [row(["dev"])] }, null)).toEqual([]);
  });

  // A fresh array on every call is a render loop where this is read: the
  // page's selector compares by reference.
  it("answers the same empty array every time", () => {
    const state = { rows: [] };
    expect(packageRequiredBy(state, place())).toBe(
      packageRequiredBy(state, place()),
    );
  });
});
