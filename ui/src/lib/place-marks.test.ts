import { describe, expect, it } from "vitest";
import type { Scope } from "@/bindings";
import { USER_LEVEL_PLACE } from "@/lib/copy-updates";
import type { PlaceStanding } from "./customized-places";
import { packageMark } from "./place-marks";

const GLOBAL: Scope = { scope: "global" };
const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };
const KENDEX: Scope = { scope: "project", root: "/work/kendex" };

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

describe("packageMark", () => {
  it("names the place and counts the rest", () => {
    const got = packageMark([stock(GLOBAL), mine(VG), stock(HYPR)]);
    expect(got?.label).toBe("Customized in vg · 1 of 3 places");
    expect(got?.goTo).toEqual(VG);
  });

  it("names the place without a count when there is only one", () => {
    expect(packageMark([mine(VG)])?.label).toBe("Customized in vg");
  });

  it("says nothing where nothing is customized", () => {
    expect(packageMark([stock(GLOBAL), stock(VG)])).toBeNull();
  });

  // A count over places nobody read is a number with no meaning behind it.
  it("drops the count while a place is unread", () => {
    const got = packageMark([mine(VG), unknown(HYPR)]);
    expect(got?.label).toBe("Customized in vg");
  });

  it("names both places and leads nowhere in particular", () => {
    const got = packageMark([mine(VG), mine(HYPR), stock(GLOBAL)]);
    expect(got?.label).toBe("Customized in vg and hyprtrade · 2 of 3 places");
    expect(got?.goTo).toBeNull();
  });
});

// The bug this rule was written for: a Library row said "3 of 3 places"
// while the package's own header said "Customized in hyprtrade", and
// nothing on either told the reader they answered different questions.
describe("one rule wherever the mark is drawn", () => {
  it("answers the same for a package however the page was opened at it", () => {
    const standings = [mine(HYPR), mine(KENDEX), mine(VG)];
    const label = "Customized in hyprtrade, kendex and vg · 3 of 3 projects";
    expect(packageMark(standings)?.label).toBe(label);
    // The same standings read in any order are the same fact about the
    // package; nothing here takes a place to answer about.
    expect(packageMark([...standings].reverse())?.label).toContain(
      "3 of 3 projects",
    );
  });
});

describe("the word a count is in", () => {
  it("calls a set of projects projects", () => {
    expect(packageMark([mine(VG), stock(HYPR)])?.label).toBe(
      "Customized in vg · 1 of 2 projects",
    );
  });

  // The personal scope is not a project, so the set it is in is mixed and
  // takes the word the rest of the app uses for a mixed set.
  it("calls a set holding the personal scope places", () => {
    expect(packageMark([mine(VG), stock(GLOBAL)])?.label).toBe(
      "Customized in vg · 1 of 2 places",
    );
    expect(packageMark([mine(GLOBAL), stock(VG)])?.label).toBe(
      `Customized in ${USER_LEVEL_PLACE} · 1 of 2 places`,
    );
  });
});

// A list a person would write: commas up to the last name, one "and"
// before it, no serial comma. Two names take the "and" alone.
describe("how the names are joined", () => {
  const DOCS: Scope = { scope: "project", root: "/work/docs" };

  it("joins two with and", () => {
    expect(packageMark([mine(VG), mine(HYPR)])?.label).toBe(
      "Customized in vg and hyprtrade · 2 of 2 projects",
    );
  });

  it("joins three as a comma list ending in and", () => {
    expect(packageMark([mine(VG), mine(HYPR), mine(KENDEX)])?.label).toBe(
      "Customized in vg, hyprtrade and kendex · 3 of 3 projects",
    );
  });

  it("keeps to one and however many places there are", () => {
    const label =
      packageMark([mine(VG), mine(HYPR), mine(KENDEX), mine(DOCS)])?.label ??
      "";
    expect(label).toBe(
      "Customized in vg, hyprtrade, kendex and docs · 4 of 4 projects",
    );
    expect(label.match(/ and /g)).toHaveLength(1);
  });

  it("names one place on its own", () => {
    expect(packageMark([mine(VG)])?.label).toBe("Customized in vg");
  });
});

// Two projects can end in the same folder name. A mark that names only the
// last folder points at both and identifies neither.
const CLIENT_A: Scope = { scope: "project", root: "/work/client" };
const CLIENT_B: Scope = { scope: "project", root: "/personal/client" };

describe("places that share a folder name", () => {
  it("names enough of the path to tell them apart", () => {
    const got = packageMark([mine(CLIENT_A), stock(CLIENT_B)]);
    expect(got?.label).toContain("work/client");
    expect(got?.label).not.toContain("personal/client");
  });
});
