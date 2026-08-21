import { describe, expect, it } from "vitest";
import { libraryViewFromHandoff } from "./library-handoff";

describe("libraryViewFromHandoff", () => {
  it("asks for everything when the link names nothing", () => {
    expect(libraryViewFromHandoff({})).toEqual({
      kind: "any",
      harness: "any",
      tag: "any",
      from: "any",
      search: "",
      scope: "all",
      scrollTop: 0,
    });
  });

  it("keeps only the narrowing the link named", () => {
    expect(libraryViewFromHandoff({ kind: "hook" })).toEqual({
      kind: "hook",
      harness: "any",
      tag: "any",
      from: "any",
      search: "",
      scope: "all",
      scrollTop: 0,
    });
    expect(libraryViewFromHandoff({ harness: "claude" })).toEqual({
      kind: "any",
      harness: "claude",
      tag: "any",
      from: "any",
      search: "",
      scope: "all",
      scrollTop: 0,
    });
  });

  it("looks where the link asked", () => {
    expect(libraryViewFromHandoff({ scope: { project: "/x" } })).toEqual({
      kind: "any",
      harness: "any",
      tag: "any",
      from: "any",
      search: "",
      scope: { project: "/x" },
      scrollTop: 0,
    });
  });

  it("leaves the stored view standing when no link opened the page", () => {
    expect(libraryViewFromHandoff(null)).toBeNull();
  });
});
