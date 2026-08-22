import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ObservedItem, Scope } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
import { type PlaceStanding, placeStandings } from "@/lib/customized-places";
import { groupItems, type ItemGroup } from "@/lib/derive";
import type { Draft } from "@/lib/editor-draft";
import { markNav } from "@/lib/place-marks";
import {
  changed,
  EVERYWHERE,
  forkedHere,
  HYPR,
  plainManifests,
  source,
  VG,
} from "@/lib/places-test-source";
import { InstalledTable } from "./installed-table";

// The row is mocked to hand back the handlers it was given: a click cannot
// be invoked through static markup, and what this pins is the argument the
// table passes, not React's dispatch.
const renderedRows: {
  group: ItemGroup;
  standings: PlaceStanding[];
  onOpen: (group: ItemGroup) => void;
  onOpenPlace: (group: ItemGroup, standings: PlaceStanding[]) => void;
}[] = [];
vi.mock("@/components/library/installed-row", () => ({
  InstalledRow: (props: (typeof renderedRows)[number]) => {
    renderedRows.push(props);
    return null;
  },
}));

const goToPackage = vi.hoisted(() => vi.fn());
vi.mock("@/stores/nav", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/nav")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useNavStore.getState(), goToPackage };
    return selector ? selector(state) : state;
  };
  return { ...mod, useNavStore: Object.assign(hook, mod.useNavStore) };
});

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so both stores are wrapped to let a test stage what each place
// holds.
const stub = vi.hoisted(() => ({
  saved: {} as Record<string, unknown>,
  scope: { scope: "global" } as unknown,
  draft: null as unknown,
  rows: [] as unknown[],
}));

vi.mock("@/stores/editor", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/editor")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useEditorStore.getState(),
      scope: stub.scope,
      draft: stub.draft,
      saved: stub.saved,
      manifestsLoaded: true,
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useEditorStore: Object.assign(hook, mod.useEditorStore) };
});

vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useUpdatesStore.getState(),
      rows: stub.rows,
      loaded: true,
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useUpdatesStore: Object.assign(hook, mod.useUpdatesStore) };
});

const ROOTS = ["/work/vg", "/work/hyprtrade"];

const install = (scope: Scope): ObservedItem => ({
  kind: "skill",
  name: "gh",
  harness: "claude",
  scope,
  path: "/h/.claude/skills/gh",
  fileState: { state: "dir" },
  enabled: true,
  origin: null,
  description: null,
  tags: [],
  modifiedAt: null,
  vendor: null,
});

const render = () =>
  renderToStaticMarkup(
    <InstalledTable
      groups={groupItems([
        install({ scope: "global" }),
        ...ROOTS.map((root) => install({ scope: "project", root })),
      ])}
      origins={new Map()}
      scanning={false}
      hasAnyItems={true}
      onClearFilters={() => {}}
      onBrowse={() => {}}
    />,
  );

beforeEach(() => {
  stub.saved = plainManifests();
  stub.scope = { scope: "global" };
  stub.draft = null;
  renderedRows.length = 0;
  goToPackage.mockClear();
  stub.rows = [null, ...ROOTS].map((root) =>
    updateRow("gh", root, { updateAvailable: false }),
  );
});

// The key to a colour is noise when nothing on screen carries it, and a
// missing key is a colour nobody can read.
describe("the Library table's colour key", () => {
  it("prints the key when a row is marked", () => {
    stub.saved = { ...stub.saved, "/work/vg": changed() };
    expect(render()).toContain("No changes of yours found");
  });

  it("leaves the key off when nothing is marked", () => {
    expect(render()).not.toContain("No changes of yours found");
  });

  // The Library answers what is customized, not what someone is typing:
  // an unsaved draft has changed nothing in kendex.toml or on disk, and
  // leaving the page without saving throws it away.
  it("ignores a draft that has not been saved", () => {
    stub.scope = VG;
    stub.draft = changed();
    const html = render();
    expect(html).not.toContain("No changes of yours found");
    expect(html).not.toContain("Customized in");
  });
});

// The mark names a place and a surface. Both are what makes it worth
// clicking: the row already opens the package's first install.
describe("where the customized mark leads", () => {
  const nav = (manifests: Record<string, Draft>) =>
    markNav(
      { kind: "skill", name: "gh" },
      placeStandings(source({ manifests }), "skill", "gh", EVERYWHERE),
    );

  it("opens the Customize tab of the place whose settings were changed", () => {
    expect(nav({ ...plainManifests(), "/work/hyprtrade": changed() })).toEqual([
      { kind: "skill", name: "gh", scope: HYPR },
      { mode: "customize" },
    ]);
  });

  it("opens the overview where the change is in the files", () => {
    expect(nav({ ...plainManifests(), "/work/vg": forkedHere() })).toEqual([
      { kind: "skill", name: "gh", scope: VG },
      undefined,
    ]);
  });

  it("leads nowhere when no place is changed", () => {
    expect(nav(plainManifests())).toBe(null);
  });
});

// The mark names a place; the row it sits in opens the package's first
// install. The table has to send the click to the place the mark named.
describe("what the table does with the mark's click", () => {
  it("opens the marked place, on the surface holding its change", () => {
    stub.saved = { ...plainManifests(), "/work/hyprtrade": changed() };
    render();
    expect(renderedRows).toHaveLength(1);
    const row = renderedRows[0];
    row.onOpenPlace(row.group, row.standings);
    expect(goToPackage).toHaveBeenCalledWith(
      { kind: "skill", name: "gh", scope: HYPR },
      { mode: "customize" },
    );
  });

  it("leaves the row's own click on the package's first install", () => {
    render();
    const row = renderedRows[0];
    row.onOpen(row.group);
    expect(goToPackage).toHaveBeenCalledWith({
      kind: "skill",
      name: "gh",
      scope: { scope: "global" },
    });
  });
});
