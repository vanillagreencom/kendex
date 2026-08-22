import { describe, expect, it } from "vitest";
import { updateRow } from "@/components/updates-test-rows";
import { changed, plainManifests, source, VG } from "@/lib/places-test-source";
import {
  indexRows,
  placeStandings,
  uncheckedPlaces,
} from "./customized-places";
import { scopeKey } from "./scope";

// A pass where one project's manifest would not load keeps the last one
// that did, so its mark does not vanish mid-read. That copy answers for an
// earlier moment, and the whole point of these marks is that an answer
// nobody could re-check is not a fact.
describe("a place whose last manifest read failed", () => {
  it("reads as unknown rather than reusing the copy it kept", () => {
    const stale = placeStandings(
      source({
        manifests: { ...plainManifests(), [scopeKey(VG)]: changed() },
        unreadPlaces: new Set([scopeKey(VG)]),
      }),
      "skill",
      "gh",
      [VG],
    );
    expect(stale[0].state).toBe("unknown");
    expect(uncheckedPlaces(stale)).toBe(1);

    // The same manifest, read this pass, is a fact and is marked.
    const fresh = placeStandings(
      source({ manifests: { ...plainManifests(), [scopeKey(VG)]: changed() } }),
      "skill",
      "gh",
      [VG],
    );
    expect(fresh[0].state).toBe("customized");
  });
});

// Both reads failing is the case where nothing can speak for the place:
// the manifest is masked, and the row the check left behind answers for
// whatever was true before it stopped finishing.
describe("a place whose manifest and update read both failed", () => {
  it("does not keep calling it forked from the row it kept", () => {
    const standings = placeStandings(
      source({
        manifests: {},
        unreadPlaces: new Set([scopeKey(VG)]),
        manifestsRead: "failed",
        updatesRead: "failed",
        rows: indexRows([
          updateRow("gh", scopeKey(VG), {
            forked: true,
            updateAvailable: false,
          }),
        ]),
      }),
      "skill",
      "gh",
      [VG],
    );
    expect(standings[0].forked).toBe(false);
    expect(standings[0].state).toBe("unknown");
  });

  it("still trusts the row while the check itself succeeded", () => {
    const standings = placeStandings(
      source({
        manifests: {},
        unreadPlaces: new Set([scopeKey(VG)]),
        manifestsRead: "failed",
        updatesRead: "ready",
        rows: indexRows([
          updateRow("gh", scopeKey(VG), {
            forked: true,
            updateAvailable: false,
          }),
        ]),
      }),
      "skill",
      "gh",
      [VG],
    );
    expect(standings[0].forked).toBe(true);
  });
});
