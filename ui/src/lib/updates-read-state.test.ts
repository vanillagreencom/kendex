import { describe, expect, it } from "vitest";
import { updatesReadState } from "./updates-read-state";

describe("updatesReadState", () => {
  it("is pending before the first read answers", () => {
    expect(updatesReadState({ loaded: false, error: null })).toBe("pending");
  });

  it("is landed once a read has answered", () => {
    expect(updatesReadState({ loaded: true, error: null })).toBe("landed");
  });

  // A failed re-read keeps the rows it had and drops `loaded`: the rows
  // are last-known, and the state has to say so rather than "pending".
  it("is failed when the read said why, whatever is still on screen", () => {
    expect(updatesReadState({ loaded: false, error: "no network" })).toBe(
      "failed",
    );
  });
});
