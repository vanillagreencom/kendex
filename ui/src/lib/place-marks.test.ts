import { describe, expect, it } from "vitest";
import type { Scope } from "@/bindings";
import type { PlaceStanding } from "./customized-places";
import { headerMark, libraryMark } from "./place-marks";

const GLOBAL: Scope = { scope: "global" };
const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };

const mine = (scope: Scope): PlaceStanding => ({
  scope,
  standing: "customized",
  why: "settings",
});
const stock = (scope: Scope): PlaceStanding => ({
  scope,
  standing: "stock",
  why: null,
});
const unknown = (scope: Scope): PlaceStanding => ({
  scope,
  standing: "unknown",
  why: null,
});

describe("libraryMark", () => {
  it("names the place and counts the rest", () => {
    const got = libraryMark([stock(GLOBAL), mine(VG), stock(HYPR)]);
    expect(got?.label).toBe("Customized in vg · 1 of 3 places");
    expect(got?.goTo).toEqual(VG);
  });

  it("names the place without a count when there is only one", () => {
    expect(libraryMark([mine(VG)])?.label).toBe("Customized in vg");
  });

  it("says nothing where nothing is customized", () => {
    expect(libraryMark([stock(GLOBAL), stock(VG)])).toBeNull();
  });

  // A count over places nobody read is a number with no meaning behind it.
  it("drops the count while a place is unread", () => {
    const got = libraryMark([mine(VG), unknown(HYPR)]);
    expect(got?.label).toBe("Customized in vg");
  });

  it("names both places and leads nowhere in particular", () => {
    const got = libraryMark([mine(VG), mine(HYPR), stock(GLOBAL)]);
    expect(got?.label).toBe("Customized in vg and hyprtrade · 2 of 3 places");
    expect(got?.goTo).toBeNull();
  });
});

describe("headerMark", () => {
  // The header names a place, so its badge answers for that place — not
  // for whichever place the package happens to be customized in.
  it("answers for the place the page is showing", () => {
    const standings = [mine(VG), stock(HYPR)];
    expect(headerMark(standings, VG)?.label).toBe("Customized in vg");
    expect(headerMark(standings, HYPR)).toBeNull();
  });

  it("finds the place by value, not by identity", () => {
    const got = headerMark([mine(VG)], { scope: "project", root: "/work/vg" });
    expect(got?.label).toBe("Customized in vg");
  });
});

// Two projects can end in the same folder name. A mark that names only the
// last folder points at both and identifies neither.
const CLIENT_A: Scope = { scope: "project", root: "/work/client" };
const CLIENT_B: Scope = { scope: "project", root: "/personal/client" };

describe("places that share a folder name", () => {
  it("names enough of the path to tell them apart on a row", () => {
    const got = libraryMark([mine(CLIENT_A), stock(CLIENT_B)]);
    expect(got?.label).toContain("work/client");
    expect(got?.label).not.toContain("personal/client");
  });

  it("tells them apart in the header too", () => {
    const standings = [mine(CLIENT_A), stock(CLIENT_B)];
    expect(headerMark(standings, CLIENT_A)?.label).toBe(
      "Customized in work/client",
    );
  });
});
