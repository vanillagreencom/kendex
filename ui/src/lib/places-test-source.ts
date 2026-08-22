import type { Scope } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
import { indexRows, type PlacesSource } from "@/lib/customized-places";
import { type Draft, emptyDraft } from "@/lib/editor-draft";

/** The three places one package lives in across the per-place tests, and
 *  the manifests that make each of them yours. */
export const GLOBAL: Scope = { scope: "global" };
export const VG: Scope = { scope: "project", root: "/work/vg" };
export const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };
export const EVERYWHERE = [GLOBAL, VG, HYPR];

/** Changed on the Customize tab: an overlay in that place's manifest. */
export const changed = (): Draft => ({
  ...emptyDraft(),
  "skill-instructions": { gh: "use the CLI" },
});

/** A place whose copy of the package is its own: forking rewrites the
 *  declaration to a local source, which the update check has no versions
 *  for — the fact lives in this place's manifest. */
export const forkedHere = (): Draft => ({
  ...emptyDraft(),
  forks: { skill: { gh: { source: "cat", "forked-at": "2026-08-01" } } },
});

export const plainManifests = (): Record<string, Draft> => ({
  global: emptyDraft(),
  "/work/vg": emptyDraft(),
  "/work/hyprtrade": emptyDraft(),
});

/** Every place readable and up to date, so each test names the one fact
 *  it is about. */
export const source = (over: Partial<PlacesSource> = {}): PlacesSource => ({
  manifests: plainManifests(),
  rows: indexRows(
    EVERYWHERE.map((scope) =>
      updateRow("gh", scope.scope === "global" ? null : scope.root, {
        updateAvailable: false,
      }),
    ),
  ),
  updatesRead: "ready",
  manifestsRead: "ready",
  unreadPlaces: new Set<string>(),
  manifestsReading: false,
  updatesReading: false,
  ...over,
});
