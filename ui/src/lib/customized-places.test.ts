import { describe, expect, it } from "vitest";
import type { Scope, ScopeSettings, SettingsRow, UpdateRow } from "@/bindings";
import { customizedLine } from "@/lib/copy-customize";
import type { Draft } from "@/lib/editor-draft";
import { packageMark } from "@/lib/place-marks";
import {
  customizedHere,
  manifestsForEditing,
  placeStandings,
  placesSource,
} from "./customized-places";

const GLOBAL: Scope = { scope: "global" };
const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };

const empty = (): Draft => ({ schema: 1, install: {} });

const withSetting = (): Draft => ({
  schema: 1,
  install: {},
  "skill-instructions": { gh: "mine" },
});

function row(scope: Scope, over: Partial<UpdateRow> = {}): UpdateRow {
  return {
    scope,
    kind: "skill",
    name: "gh",
    source: "cat",
    repo: "o/r",
    repoIdentity: "o/r",
    current: null,
    latest: null,
    updateAvailable: false,
    pinned: false,
    holdOwner: null,
    ignored: false,
    blockedByLocalEdit: false,
    editedHarnesses: [],
    forkableHarness: null,
    canDiscard: false,
    forked: false,
    ...over,
  } as UpdateRow;
}

const key = (over: Partial<SettingsRow> = {}): SettingsRow => ({
  key: "GH_MODE",
  explainer: ["what it does"],
  default: "enforce",
  current: { state: "value", value: "enforce", line: 3 },
  ...over,
});

/** One place's read: every skill named here declaring one key, whose
 *  value is the package default unless the row says otherwise. */
const read = (skills: Record<string, SettingsRow[]>): ScopeSettings => ({
  applies: true,
  base: "b1",
  skills: Object.entries(skills).map(([skill, rows]) => ({
    skill,
    template: { state: "rows", rows },
  })),
});

function source({
  manifests = {},
  rows = [],
  updatesLoaded = true,
  settings = Object.fromEntries(
    Object.keys(manifests).map((at) => [at, read({})]),
  ),
}: {
  manifests?: Record<string, Draft>;
  rows?: UpdateRow[];
  updatesLoaded?: boolean;
  /** Absent for a place means its read has not landed. */
  settings?: Record<string, ScopeSettings>;
} = {}) {
  return placesSource(manifests, rows, updatesLoaded, settings);
}

describe("placeStandings", () => {
  it("marks only the place that holds the change", () => {
    const s = source({
      manifests: {
        global: empty(),
        "/work/vg": withSetting(),
        "/work/hyprtrade": empty(),
      },
      rows: [row(GLOBAL), row(VG), row(HYPR)],
    });
    const got = placeStandings(s, "skill", "gh", [GLOBAL, VG, HYPR]);
    expect(got.map((p) => p.standing)).toEqual([
      "stock",
      "customized",
      "stock",
    ]);
    expect(got[1].why).toBe("settings");
  });

  it("counts a hand-edited place even when nothing is out of date", () => {
    const s = source({
      manifests: { "/work/vg": empty() },
      rows: [row(VG, { blockedByLocalEdit: true })],
    });
    const [only] = placeStandings(s, "skill", "gh", [VG]);
    expect(only.standing).toBe("customized");
    expect(only.why).toBe("edited");
  });

  it("counts a forked place from its own manifest", () => {
    const forkedDraft: Draft = {
      schema: 1,
      install: {},
      forks: { skill: { gh: { source: "local", "forked-at": "2026-01-01" } } },
    };
    const s = source({ manifests: { "/work/vg": forkedDraft } });
    const [only] = placeStandings(s, "skill", "gh", [VG]);
    expect(only.standing).toBe("customized");
    expect(only.why).toBe("forked");
  });

  // The Library's Forked badge reads `why`, and a fork with an instruction
  // typed on top is still a fork: settings must not outrank it.
  it("says forked over settings when both hold", () => {
    const forkedWithSetting: Draft = {
      ...withSetting(),
      forks: { skill: { gh: { source: "local", "forked-at": "2026-01-01" } } },
    };
    const s = source({ manifests: { "/work/vg": forkedWithSetting } });
    const [only] = placeStandings(s, "skill", "gh", [VG]);
    expect(only.why).toBe("forked");
  });

  // A place the app never read must not be reported as the author wrote
  // it: not knowing and knowing it is clean are different answers.
  it("leaves a place whose manifest was never read unknown", () => {
    const s = source({ manifests: {}, rows: [row(VG)] });
    const [only] = placeStandings(s, "skill", "gh", [VG]);
    expect(only.standing).toBe("unknown");
  });

  it("leaves a local-source place unknown: the engine has no row for it", () => {
    const s = source({ manifests: { "/work/vg": empty() }, rows: [] });
    const [only] = placeStandings(s, "skill", "gh", [VG]);
    expect(only.standing).toBe("unknown");
  });

  it("does not call a place stock before the update read has landed", () => {
    const s = source({
      manifests: { "/work/vg": empty() },
      rows: [],
      updatesLoaded: false,
    });
    const [only] = placeStandings(s, "skill", "gh", [VG]);
    expect(only.standing).toBe("unknown");
  });

  /// A settings file answering a declared key off the package default is
  /// this place's own customization, whatever the manifest says.
  it("marks a place whose settings file answers a key off the default", () => {
    const s = source({
      manifests: { "/work/vg": empty() },
      rows: [row(VG)],
      settings: {
        "/work/vg": read({
          gh: [key({ current: { state: "value", value: "advise", line: 3 } })],
        }),
      },
    });
    const [only] = placeStandings(s, "skill", "gh", [VG]);
    expect(only.standing).toBe("customized");
    expect(only.why).toBe("values");
  });

  /// Only a `value` current is comparable with the default: an ambiguous
  /// key says what is in the way, never what the value is, so nothing can
  /// call it off the default.
  it("does not mark a place over a key nothing can read a value from", () => {
    const s = source({
      manifests: { "/work/vg": empty() },
      rows: [row(VG)],
      settings: {
        "/work/vg": read({
          gh: [
            key({
              current: { state: "ambiguous", problem: "twice", lines: [3, 9] },
            }),
          ],
        }),
      },
    });
    const [only] = placeStandings(s, "skill", "gh", [VG]);
    expect(only.standing).toBe("stock");
  });

  /// The settings read is a fourth source, and a place it has not spoken
  /// about is unknown rather than stock — the same rule the other three
  /// answer to.
  it("does not call a place stock before its settings read has landed", () => {
    const s = source({
      manifests: { "/work/vg": empty() },
      rows: [row(VG)],
      settings: {},
    });
    const [only] = placeStandings(s, "skill", "gh", [VG]);
    expect(only.standing).toBe("unknown");
  });

  /// Global has no settings file, and `applies: false` with no skills is
  /// the whole answer for it — a place that resolves the fact to false
  /// rather than leaving every package there unknown forever.
  it("resolves the fact to false on global's known-empty answer", () => {
    const s = source({
      manifests: { global: empty() },
      rows: [row(GLOBAL)],
      settings: { global: { applies: false, skills: [], base: null } },
    });
    const [only] = placeStandings(s, "skill", "gh", [GLOBAL]);
    expect(only.standing).toBe("stock");
  });

  // The row is re-read with the write; the saved manifest is not. Reading
  // only the manifest loses the fork at the moment it is made.
  it("takes a fork the row knows about but the saved manifest predates", () => {
    const s = source({
      manifests: { "/work/vg": empty() },
      rows: [row(VG, { forked: true })],
    });
    const [only] = placeStandings(s, "skill", "gh", [VG]);
    expect(only.standing).toBe("customized");
    expect(only.why).toBe("forked");
  });
});

describe("customizedHere", () => {
  // The Library marks a hand-edited package "Customized in vg"; the page
  // headed "Customized packages" for vg has to list it, or the mark leads
  // to a page that denies it.
  it("lists a hand-edit-only package the Library row marks", () => {
    const s = source({
      manifests: { "/work/vg": empty() },
      rows: [row(VG, { blockedByLocalEdit: true })],
    });
    const mark = packageMark(placeStandings(s, "skill", "gh", [VG]));
    expect(mark?.label).toBe("Customized in vg");
    expect(mark?.why).toBe("edited");
    expect(customizedHere(s, VG)).toMatchObject([
      { kind: "skill", name: "gh", edited: true, forked: false },
    ]);
  });

  /// The Library marks the place, so the index behind that mark has to
  /// carry the row — a settings value is the only fact making it theirs.
  it("lists a package the settings file alone makes theirs", () => {
    const s = source({
      manifests: { "/work/vg": empty() },
      rows: [row(VG)],
      settings: {
        "/work/vg": read({
          gh: [key({ current: { state: "value", value: "advise", line: 3 } })],
        }),
      },
    });
    expect(customizedHere(s, VG)).toMatchObject([
      { kind: "skill", name: "gh", values: true, edited: false },
    ]);
  });

  // A fork is in the manifest before any update row says so, and a local
  // source never gets a row at all: the forks table alone has to carry it.
  it("lists a fork the manifest alone records", () => {
    const manifest: Draft = {
      ...empty(),
      forks: { skill: { gh: { source: "cat", repo: "o/r" } as never } },
    };
    for (const updatesLoaded of [true, false]) {
      const s = source({ manifests: { "/work/vg": manifest }, updatesLoaded });
      expect(customizedHere(s, VG)).toMatchObject([
        {
          kind: "skill",
          name: "gh",
          forked: true,
          edited: false,
          customization: {
            launch: null,
            additional: null,
            instructions: null,
            skills: null,
            frontmatter: [],
          },
        },
      ]);
    }
  });

  // Settings outrank a hand edit for where a click lands, but the row's
  // line names both: the edit is what holds updates back.
  it("names a hand edit under a package that also has settings", () => {
    const s = source({
      manifests: { "/work/vg": withSetting() },
      rows: [row(VG, { blockedByLocalEdit: true })],
    });
    const [only] = customizedHere(s, VG);
    expect(only).toMatchObject({ edited: true, forked: false });
    expect(customizedLine(only, only.customization)).toBe(
      "Edited by you · Extra instructions",
    );
  });

  it("lists a fork recorded in the manifest, with its settings", () => {
    const manifest: Draft = {
      ...withSetting(),
      forks: { skill: { gh: { source: "cat", repo: "o/r" } as never } },
    };
    const s = source({ manifests: { "/work/vg": manifest } });
    expect(customizedHere(s, VG)).toMatchObject([
      {
        kind: "skill",
        name: "gh",
        forked: true,
        customization: { instructions: "mine" },
      },
    ]);
  });

  it("lists a settings-only package with what was set", () => {
    const s = source({ manifests: { "/work/vg": withSetting() } });
    expect(customizedHere(s, VG)).toMatchObject([
      { kind: "skill", name: "gh", edited: false, forked: false },
    ]);
  });

  it("leaves out stock rows and other places' settings", () => {
    const s = source({
      manifests: { "/work/vg": empty(), "/work/hyprtrade": withSetting() },
      rows: [row(VG), row(HYPR, { blockedByLocalEdit: true })],
    });
    expect(customizedHere(s, VG)).toEqual([]);
  });

  // Before the update read lands, a hand edit is not a fact anyone holds;
  // the list is the manifest's until it does, never a guess.
  // A row's fork fact is held back the same way: rows kept from before a
  // failed re-read are last-known, and a fork discarded since would still
  // be on them.
  it("holds a hand edit and a row's fork back until the update read has landed", () => {
    const s = source({
      manifests: { "/work/vg": withSetting() },
      rows: [
        row(VG, { blockedByLocalEdit: true }),
        row(VG, { kind: "agent", name: "orch", blockedByLocalEdit: true }),
        row(VG, { name: "zed", forked: true }),
      ],
      updatesLoaded: false,
    });
    expect(customizedHere(s, VG)).toMatchObject([
      { kind: "skill", name: "gh", edited: false },
    ]);
    const [zed] = placeStandings(s, "skill", "zed", [VG]);
    expect(zed.standing).toBe("unknown");
  });

  it("orders agents before skills, each by name", () => {
    const s = source({
      manifests: { "/work/vg": withSetting() },
      rows: [
        row(VG, { name: "zed", blockedByLocalEdit: true }),
        row(VG, { kind: "agent", name: "orch", forked: true }),
      ],
    });
    expect(customizedHere(s, VG).map((r) => `${r.kind}:${r.name}`)).toEqual([
      "agent:orch",
      "skill:gh",
      "skill:zed",
    ]);
  });
});

describe("manifestsForEditing", () => {
  // Remove edits the draft, and the row it removes has to go with it
  // before a save; the saved manifest still holds the setting until then.
  it("reads the open draft in place of that place's saved manifest", () => {
    const saved = { "/work/vg": withSetting(), global: withSetting() };
    const manifests = manifestsForEditing(saved, empty(), VG);
    const places = source({ manifests });
    expect(customizedHere(places, VG)).toEqual([]);
    expect(customizedHere(places, GLOBAL)).toHaveLength(1);
  });

  it("leaves the saved manifests alone while there is no draft", () => {
    const saved = { "/work/vg": withSetting() };
    expect(manifestsForEditing(saved, null, VG)).toBe(saved);
  });
});
