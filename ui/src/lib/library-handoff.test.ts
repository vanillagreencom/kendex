import { describe, expect, it } from "vitest";
import {
  isNarrowed,
  type LibraryView,
  libraryViewFromHandoff,
  UNFILTERED,
} from "./library-handoff";

const EVERYTHING: LibraryView = {
  filters: { kind: "any", harness: "any", tag: "any", from: "any" },
  search: "",
  scope: "all",
};

describe("libraryViewFromHandoff", () => {
  it("asks for everything when the link names nothing", () => {
    expect(libraryViewFromHandoff({})).toEqual(EVERYTHING);
    expect(UNFILTERED).toEqual(EVERYTHING);
  });

  it("keeps only the narrowing the link named", () => {
    expect(libraryViewFromHandoff({ kind: "hook" })).toEqual({
      ...EVERYTHING,
      filters: { ...EVERYTHING.filters, kind: "hook" },
    });
    expect(libraryViewFromHandoff({ harness: "claude" })).toEqual({
      ...EVERYTHING,
      filters: { ...EVERYTHING.filters, harness: "claude" },
    });
  });

  it("looks where the link asked", () => {
    expect(libraryViewFromHandoff({ scope: { project: "/x" } })).toEqual({
      ...EVERYTHING,
      scope: { project: "/x" },
    });
  });

  it("looks at the personal setup alone when the link asked for that", () => {
    expect(libraryViewFromHandoff({ scope: "global" })).toEqual({
      ...EVERYTHING,
      scope: "global",
    });
  });

  it("leaves the stored view standing when no link opened the page", () => {
    expect(libraryViewFromHandoff(null)).toBeNull();
  });
});

describe("isNarrowed", () => {
  it("says a view showing everything is holding nothing back", () => {
    expect(isNarrowed(EVERYTHING)).toBe(false);
  });

  it("counts every picker on the strip", () => {
    for (const name of ["kind", "harness", "tag", "from"] as const) {
      expect(
        isNarrowed({
          ...EVERYTHING,
          filters: { ...EVERYTHING.filters, [name]: "something" },
        }),
      ).toBe(true);
    }
  });

  it("counts the search box and where the table is looking", () => {
    expect(isNarrowed({ ...EVERYTHING, search: "deploy" })).toBe(true);
    expect(isNarrowed({ ...EVERYTHING, scope: "global" })).toBe(true);
    expect(isNarrowed({ ...EVERYTHING, scope: { project: "/x" } })).toBe(true);
  });
});
