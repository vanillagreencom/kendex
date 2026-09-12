// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  HarnessId,
  ItemKind,
  ObservedItem,
  Origin,
  ProvenanceRow,
  Scope,
} from "@/bindings";
import { InstalledView } from "@/components/library/installed-view";
import { openLibraryAt } from "@/components/library/use-filter-handoff";
import {
  FORKED_BADGE_LABEL,
  MISSING_FILES_BADGE_LABEL,
  UPDATES_NOTHING_INSTALLED as NOTHING_INSTALLED,
  PACKAGES_CHECK_FAILED_TITLE,
  PACKAGES_UNCONFIRMED_TITLE,
  TAGS_ROW_LABEL,
  TRY_AGAIN_LABEL,
} from "@/lib/copy";
import { STATUS_LABELS } from "@/lib/copy-customize";
import { addPackagesTo, nothingInstalledIn } from "@/lib/copy-install";
import { UPDATE_AVAILABLE_BADGE } from "@/lib/copy-updates";
import { observedAt } from "@/lib/derive";
import {
  READ_LANDED,
  READ_PENDING,
  type ReadState,
  readFailed,
} from "@/lib/read-state";
import { useEditorStore } from "@/stores/editor";
import { NO_FILTERS, useLibraryViewStore } from "@/stores/library-view";
import { useNavStore } from "@/stores/nav";
import { useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import { useUpdatesStore } from "@/stores/updates";
import { mount, roomIs } from "@/test/dom";
import { joinAnswered } from "@/test/identity-join";
import { observed } from "@/test/observed";

const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };

const installed = (scope: Scope): ObservedItem =>
  ({
    kind: "skill",
    name: "gh",
    scope,
    harness: "claude",
    path: `${scope.scope === "project" ? scope.root : ""}/.claude/skills/gh`,
    fileState: { state: "file" },
    enabled: true,
    origin: null,
    summary: "about gh",
    action: null,
    tags: [],
    modifiedAt: null,
    vendor: null,
  }) as unknown as ObservedItem;

// Customized in both places.
const mine = { schema: 1, install: {}, "skill-instructions": { gh: "mine" } };

const customizedText = (host: HTMLElement) =>
  [...host.querySelectorAll("tbody tr")]
    .map((row) => row.textContent ?? "")
    .filter((text) => text.includes("Customized"));

// The list says nothing about customization. A package customized in two
// places renders no "Customized in" line in any state — the line used to
// appear on hover through a CSS class, so the control is that no element
// carries the words at all — no legend above the table, and a kind icon
// in the same muted colour as every other row's. The package page's
// header is where the fact is said (package-header.test.tsx).
describe("a customized package in the Library list", () => {
  beforeEach(() => {
    vi.spyOn(useProvenanceStore.getState(), "load").mockResolvedValue();
    vi.spyOn(useEditorStore.getState(), "loadAll").mockResolvedValue();
    // One package customized in two places, which is what the fixture is
    // about — so the join says it is one, since two copies wearing a name
    // establish nothing on their own.
    useProvenanceStore.setState({
      rows: [VG, HYPR].map((scope) => ({
        scope,
        kind: "skill" as const,
        name: "gh",
        harness: "claude" as const,
        at: installed(scope).path,
        origin: { origin: "marketplace" as const, source: "cat", repo: "o/r" },
        summary: null,
        package: { kind: "skill" as const, name: "gh" },
      })),
      loaded: true,
      answeredFor: 0,
      read: READ_LANDED,
    });
    useEditorStore.setState({
      saved: { "/work/vg": mine as never, "/work/hyprtrade": mine as never },
    });
    useUpdatesStore.setState({ rows: [], read: READ_LANDED });
    useScanStore.setState({
      result: {
        harnesses: [],
        items: [installed(VG), installed(HYPR)],
        missingProjects: [],
        readProjects: [],
        warnings: [],
      } as never,
    });
    useLibraryViewStore.setState({ ...NO_FILTERS });
    useNavStore.setState({ libraryScope: "all", search: "" });
  });

  it("carries no mark, no legend and no customized colour", () => {
    const host = mount(<InstalledView />);
    expect(host.querySelectorAll("tbody tr")).toHaveLength(1);
    expect(customizedText(host)).toEqual([]);
    expect(host.textContent).not.toContain("Customized");
    expect(host.textContent).not.toContain("As the author wrote it");
    expect(host.querySelector(".text-customized")).toBeNull();
    expect(host.querySelector("tbody svg")?.getAttribute("class")).toContain(
      "text-muted-foreground",
    );
  });

  // The Where filter still decides which rows are on screen.
  it("still narrows the table to the place asked for", () => {
    useNavStore.setState({ libraryScope: { project: "/work/vg" }, search: "" });
    const host = mount(<InstalledView />);
    expect(host.querySelectorAll("tbody tr")).toHaveLength(1);
  });
});

// Home's edited row lands here narrowed to the packages it counted: the
// facet reads the same update rows, so a package edited on disk is on
// the page and one that is not is off it.
describe("the Library narrowed to packages edited on disk", () => {
  const other = {
    ...installed(VG),
    name: "orch",
    path: "/work/vg/.claude/skills/orch",
  };
  // orch has a row too, unedited: the facet must turn on the edit flag,
  // not on whether the updates read spoke about the package at all.
  const rows = [
    {
      kind: "skill",
      name: "gh",
      scope: VG,
      blockedByLocalEdit: true,
      editedHarnesses: ["claude"],
    },
    {
      kind: "skill",
      name: "orch",
      scope: VG,
      blockedByLocalEdit: false,
      editedHarnesses: [],
    },
  ];

  beforeEach(() => {
    vi.spyOn(useProvenanceStore.getState(), "load").mockResolvedValue();
    vi.spyOn(useEditorStore.getState(), "loadAll").mockResolvedValue();
    // The join has answered and found nothing recorded: these packages
    // are grouped as the scan saw them, which is what the fixture means.
    useProvenanceStore.setState({
      rows: [],
      loaded: true,
      answeredFor: 0,
      read: READ_LANDED,
    });
    useEditorStore.setState({ saved: {} });
    useUpdatesStore.setState({ rows: rows as never, read: READ_LANDED });
    useScanStore.setState({
      result: {
        harnesses: [],
        items: [installed(VG), other],
        missingProjects: [],
        readProjects: [],
        warnings: [],
      } as never,
    });
    useNavStore.setState({ libraryScope: "all", search: "" });
  });

  const names = (host: HTMLElement) =>
    [...host.querySelectorAll("tbody tr td:first-child")].map((cell) =>
      cell.querySelector("button")?.textContent?.trim(),
    );

  // Shaped input over one surface: what the updates read has said decides
  // whether the facet can answer. Landed and failed-with-rows are known
  // (Home draws its edited row from those rows); pending and a failed
  // first read that kept nothing have counted nothing, so the table holds
  // its skeleton rather than claiming no package is edited.
  const reads: [string, ReadState, unknown[], string[], boolean][] = [
    ["landed", READ_LANDED, rows, ["gh"], false],
    ["pending", READ_PENDING, [], [], true],
    ["failed with rows kept", readFailed("no network"), rows, ["gh"], false],
    ["failed with nothing kept", readFailed("no network"), [], [], true],
  ];

  it("answers for every known and unknown edited-package read", () => {
    expect(reads).toHaveLength(4);
    for (const [name, read, kept, expected, skeleton] of reads) {
      useUpdatesStore.setState({ rows: kept as never, read });
      useLibraryViewStore.setState({ ...NO_FILTERS, edited: "edited" });
      const host = mount(<InstalledView />);
      expect(
        names(host).filter((name) => name !== undefined),
        name,
      ).toEqual(expected);
      expect(host.querySelector('[data-slot="skeleton"]') !== null).toBe(
        skeleton,
      );
    }
  });

  it("shows every package when the facet is off", () => {
    useLibraryViewStore.setState({ ...NO_FILTERS });
    expect(names(mount(<InstalledView />))).toEqual(["gh", "orch"]);
  });
});

// The mark says an update is available, so it asks the one selection whose
// words that is: a package the source dropped has no version to move to,
// and a read that has not landed has not counted anything.
describe("the update mark on a Library row", () => {
  const row = (name: string, extra: Record<string, unknown>) => ({
    kind: "skill",
    name,
    scope: VG,
    updateAvailable: false,
    removedUpstream: false,
    mixed: false,
    ignored: false,
    blockedByLocalEdit: false,
    editedHarnesses: [],
    ...extra,
  });

  beforeEach(() => {
    vi.spyOn(useProvenanceStore.getState(), "load").mockResolvedValue();
    vi.spyOn(useEditorStore.getState(), "loadAll").mockResolvedValue();
    useEditorStore.setState({ saved: {} });
    useScanStore.setState({
      result: {
        harnesses: [],
        items: [installed(VG)],
        missingProjects: [],
        readProjects: [],
        warnings: [],
      } as never,
    });
    useNavStore.setState({ libraryScope: "all", search: "" });
    useLibraryViewStore.setState({ ...NO_FILTERS });
  });

  it("marks a package with an update and nothing else", () => {
    const cases: [string, ReadState, unknown[], boolean][] = [
      [
        "an update to take",
        READ_LANDED,
        [row("gh", { updateAvailable: true })],
        true,
      ],
      [
        "gone from its source",
        READ_LANDED,
        [row("gh", { removedUpstream: true })],
        false,
      ],
      [
        "installs disagreeing",
        READ_LANDED,
        [row("gh", { mixed: true })],
        false,
      ],
      [
        "muted",
        READ_LANDED,
        [row("gh", { updateAvailable: true, ignored: true })],
        false,
      ],
      [
        "no read has landed",
        READ_PENDING,
        [row("gh", { updateAvailable: true })],
        false,
      ],
    ];
    expect(cases).toHaveLength(5);
    for (const [name, read, rows, marked] of cases) {
      useUpdatesStore.setState({ rows: rows as never, read });
      const host = mount(<InstalledView />);
      expect(
        (host.textContent ?? "").includes(UPDATE_AVAILABLE_BADGE),
        name,
      ).toBe(marked);
    }
  });
});

// The badge says a file kendex installed here is gone, which is a fact
// about the disk like an edit: Home draws its row from the rows a failed
// re-check kept, so the badge reads them the same way, and a read that has
// counted nothing draws none.
describe("the missing files badge on a Library row", () => {
  const row = (extra: Record<string, unknown>) => ({
    kind: "skill",
    name: "gh",
    scope: VG,
    updateAvailable: false,
    removedUpstream: false,
    mixed: false,
    ignored: false,
    blockedByLocalEdit: false,
    filesMissing: false,
    editedHarnesses: [],
    ...extra,
  });

  beforeEach(() => {
    vi.spyOn(useProvenanceStore.getState(), "load").mockResolvedValue();
    vi.spyOn(useEditorStore.getState(), "loadAll").mockResolvedValue();
    useEditorStore.setState({ saved: {} });
    useScanStore.setState({
      result: {
        harnesses: [],
        items: [installed(VG)],
        missingProjects: [],
        readProjects: [],
        warnings: [],
      } as never,
    });
    useNavStore.setState({ libraryScope: "all", search: "" });
    useLibraryViewStore.setState({ ...NO_FILTERS });
  });

  it("marks the place where a file is gone, off every read that kept rows", () => {
    const cases: [string, ReadState, unknown[], boolean][] = [
      [
        "failed with rows kept",
        readFailed("no network"),
        [row({ filesMissing: true })],
        true,
      ],
      ["every file in place", READ_LANDED, [row({})], false],
      ["pending", READ_PENDING, [row({ filesMissing: true })], false],
    ];
    expect(cases).toHaveLength(3);
    for (const [name, read, rows, marked] of cases) {
      useUpdatesStore.setState({ rows: rows as never, read });
      const host = mount(<InstalledView />);
      expect(
        (host.textContent ?? "").includes(MISSING_FILES_BADGE_LABEL),
        name,
      ).toBe(marked);
    }
  });
});

// Deleting a package's rendering by hand leaves the record behind, and the
// scan then has nothing to observe: grouped from the scan alone the package
// falls off this list while Home still counts it among the ones missing
// files and links here. The row comes back off those same rows, marked, and
// its badge opens the package page where the Repair is.
describe("a package whose rendering is gone everywhere", () => {
  const row = (extra: Record<string, unknown>) => ({
    kind: "skill",
    name: "gh",
    scope: VG,
    updateAvailable: false,
    removedUpstream: false,
    mixed: false,
    ignored: false,
    blockedByLocalEdit: false,
    filesMissing: false,
    editedHarnesses: [],
    ...extra,
  });

  // The row a record seeds for an installation the scan cannot see: core
  // keys it by the declaration alone, so it carries no file.
  const seeded = {
    scope: VG,
    kind: "skill" as const,
    name: "gh",
    harness: "claude" as const,
    at: null,
    origin: { origin: "marketplace" as const, source: "cat", repo: "o/r" },
    summary: null,
    package: { kind: "skill" as const, name: "gh" },
  };

  // The same package as the scan sees it: an observation, joined to the
  // record by the file it reads.
  const here = {
    ...installed(VG),
    at: installed(VG).path,
  } as unknown as ObservedItem;
  const observedRow = { ...seeded, at: installed(VG).path };

  const scanIs = (items: ObservedItem[]) =>
    useScanStore.setState({
      result: {
        harnesses: [],
        items,
        missingProjects: [],
        readProjects: [],
        warnings: [],
      } as never,
    });

  beforeEach(() => {
    vi.spyOn(useProvenanceStore.getState(), "load").mockResolvedValue();
    vi.spyOn(useEditorStore.getState(), "loadAll").mockResolvedValue();
    useEditorStore.setState({ saved: {} });
    useNavStore.setState({ libraryScope: "all", search: "" });
    useLibraryViewStore.setState({ ...NO_FILTERS });
  });

  const names = (host: HTMLElement) =>
    [...host.querySelectorAll("tbody tr td:first-child")].map((cell) =>
      cell.querySelector("button")?.textContent?.trim(),
    );

  /** The place pills above the table, which are what a reader narrows by.
   *  A pill is the only control here that reports a pressed state. */
  const pillLabels = (host: HTMLElement) =>
    [...host.querySelectorAll("button[aria-pressed]")].map((pill) =>
      pill.textContent?.trim(),
    );

  // The row's own cells, at a width that draws every column: Name, Type,
  // Tags, Harnesses, Where, From, Updated, Status. Read from the row
  // rather than from the page, whose filter bar names the same places and
  // sources and would answer for a row that says nothing.
  const cellsOf = (host: HTMLElement) => [
    ...(host.querySelector("tbody tr")?.querySelectorAll("td") ?? []),
  ];

  it("draws the row marked, and the ordinary row once the files are back", () => {
    const cases: [string, ObservedItem[], boolean, boolean, string][] = [
      ["its rendering deleted", [], true, true, STATUS_LABELS.missing],
      ["every file in place", [here], false, false, STATUS_LABELS.active],
    ];
    expect(cases).toHaveLength(2);
    for (const [name, items, gone, marked, status] of cases) {
      scanIs(items);
      joinAnswered([gone ? seeded : observedRow] as never);
      useUpdatesStore.setState({
        rows: [row({ filesMissing: gone })] as never,
        read: READ_LANDED,
      });
      roomIs(1400);
      const host = mount(<InstalledView />);
      expect(names(host), name).toEqual(["gh"]);
      expect(
        (host.textContent ?? "").includes(MISSING_FILES_BADGE_LABEL),
        name,
      ).toBe(marked);
      const cells = cellsOf(host);
      expect(cells, name).toHaveLength(8);
      // The row stands for the place its record names, so its Where and
      // From cells answer from that place rather than from a scan that has
      // nothing to say about it.
      expect(cells[4].textContent, name).toContain("vg");
      expect(cells[5].textContent, name).toContain("cat");
      expect(cells[7].textContent, name).toContain(status);
    }
  });

  // Rows a read has not confirmed have counted nothing: a row drawn off
  // them would state as a fact that a package's files are gone before any
  // read said so. Nor may the table then say which emptiness this is —
  // "Nothing installed yet" is as definite a claim as the row would be,
  // and on a machine whose every package lost its rendering it is false.
  it("draws no row, and claims no emptiness, before a read confirms the rows", () => {
    scanIs([]);
    joinAnswered([seeded] as never);
    useUpdatesStore.setState({
      rows: [row({ filesMissing: true })] as never,
      read: READ_PENDING,
    });
    const host = mount(<InstalledView />);
    expect(names(host)).not.toContain("gh");
    expect(host.textContent).not.toContain(MISSING_FILES_BADGE_LABEL);
    expect(host.textContent).not.toContain(NOTHING_INSTALLED);
  });

  // The place pills are how a reader narrows to what a row names. Drawn
  // off the scan they would not offer a project whose every package lost
  // its rendering, leaving its row on screen and no way to look at it.
  it("offers the place pill for a project only its missing rows stand in", () => {
    scanIs([]);
    joinAnswered([seeded] as never);
    useUpdatesStore.setState({
      rows: [row({ filesMissing: true })] as never,
      read: READ_LANDED,
    });
    const host = mount(<InstalledView />);
    // The pills, not the row: the row's own Where cell names the place too
    // and would answer for a filter strip that offered nothing.
    expect(pillLabels(host)).toEqual(["Everywhere", "Personal", "vg"]);
    expect(names(host)).toContain("gh");
  });

  // Which of the two emptinesses the table shows is read off the rows it
  // could draw. Read off the scan, a machine whose only package lost its
  // rendering says "Nothing installed yet" under a filter that is merely
  // hiding the one row it has.
  it("says a filter is hiding the row, not that nothing is installed", () => {
    scanIs([]);
    joinAnswered([seeded] as never);
    useUpdatesStore.setState({
      rows: [row({ filesMissing: true })] as never,
      read: READ_LANDED,
    });
    useNavStore.setState({ search: "nothing matches this" });
    const host = mount(<InstalledView />);
    expect(names(host)).not.toContain("gh");
    expect(host.textContent).toContain("Nothing matches");
    expect(host.textContent).not.toContain(NOTHING_INSTALLED);
  });

  // The words come off the row a record seeded, which core fills for
  // exactly the rows the scan could not see — so the same author-text
  // search that found the package while its files existed still finds it.
  it("shows and searches the declared words when no copy is left", () => {
    scanIs([]);
    joinAnswered([{ ...seeded, summary: "about gh" }] as never);
    useUpdatesStore.setState({
      rows: [row({ filesMissing: true })] as never,
      read: READ_LANDED,
    });
    expect(mount(<InstalledView />).textContent).toContain("about gh");

    useNavStore.setState({ search: "about gh" });
    expect(names(mount(<InstalledView />))).toContain("gh");
  });

  // The badge on a row names every place the package is missing in,
  // because the fact is about the package wherever it is. The row's own
  // click is about the table on screen: narrowed to one project, a reader
  // means that project's page, not whichever place the rows list first.
  it("opens the narrowed place, not the first one the rows name", async () => {
    scanIs([]);
    joinAnswered([seeded] as never);
    useUpdatesStore.setState({
      // Global first, so taking the first place the rows name is the
      // wrong answer this pins.
      rows: [
        row({ scope: { scope: "global" }, filesMissing: true }),
        row({ filesMissing: true }),
      ] as never,
      read: READ_LANDED,
    });
    useNavStore.setState({ libraryScope: { project: VG.root } });
    const host = mount(<InstalledView />);
    const line = host.querySelector("tbody tr");
    if (!line) throw new Error("no row");

    await userEvent.click(line);
    expect(useNavStore.getState().packageRef).toEqual({
      kind: "skill",
      name: "gh",
      identity: "recorded",
      scope: VG,
    });
  });

  // A marketplace alias is declared at a place, so the record the From
  // column names has to be the one for the place this table is showing.
  // The badges still name every place, which is what they are for.
  it("names the narrowed place's marketplace, not the first one recorded", () => {
    scanIs([]);
    joinAnswered([
      { ...seeded, scope: { scope: "global" } },
      {
        ...seeded,
        origin: { origin: "marketplace", source: "vgcat", repo: "o/vg" },
      },
    ] as never);
    useUpdatesStore.setState({
      rows: [
        row({ scope: { scope: "global" }, filesMissing: true }),
        row({ filesMissing: true }),
      ] as never,
      read: READ_LANDED,
    });
    useNavStore.setState({ libraryScope: { project: VG.root } });
    roomIs(1400);
    const cells = cellsOf(mount(<InstalledView />));
    expect(cells).toHaveLength(8);
    expect(cells[5].textContent).toContain("vgcat");
    expect(cells[5].textContent).not.toContain("cat,");
  });

  // The From facet reads the same record the column draws, so it narrows
  // on the alias the table's own place declared. This also walks the
  // filter's own path over a row with no copy, which nothing else does.
  it("narrows on the marketplace the narrowed place declared", () => {
    scanIs([]);
    joinAnswered([
      { ...seeded, scope: { scope: "global" } },
      {
        ...seeded,
        origin: { origin: "marketplace", source: "vgcat", repo: "o/vg" },
      },
    ] as never);
    useUpdatesStore.setState({
      rows: [
        row({ scope: { scope: "global" }, filesMissing: true }),
        row({ filesMissing: true }),
      ] as never,
      read: READ_LANDED,
    });
    useNavStore.setState({ libraryScope: { project: VG.root } });

    useLibraryViewStore.setState({ ...NO_FILTERS, from: "vgcat" });
    expect(names(mount(<InstalledView />))).toContain("gh");

    useLibraryViewStore.setState({ ...NO_FILTERS, from: "cat" });
    expect(names(mount(<InstalledView />))).not.toContain("gh");
  });

  // A fork is a fork wherever it was made, and deleting its rendering does
  // not undo it. The badge is read off the places the row stands in, which
  // for this row are only the ones its record names.
  it("keeps the forked badge when the fork's last rendering is gone", () => {
    scanIs([]);
    joinAnswered([
      {
        ...seeded,
        origin: { origin: "own", forkedFrom: null, source: "local" },
      },
    ] as never);
    useEditorStore.setState({
      saved: {
        [VG.root]: {
          schema: 1,
          install: {},
          forks: {
            skill: { gh: { source: "local", "forked-at": "2026-01-01" } },
          },
        } as never,
      },
    });
    useUpdatesStore.setState({
      rows: [row({ filesMissing: true })] as never,
      read: READ_LANDED,
    });
    expect(mount(<InstalledView />).textContent).toContain(FORKED_BADGE_LABEL);
  });

  it("opens the package at the place the repair is offered", async () => {
    scanIs([]);
    joinAnswered([seeded] as never);
    useUpdatesStore.setState({
      rows: [row({ filesMissing: true })] as never,
      read: READ_LANDED,
    });
    const host = mount(<InstalledView />);
    const badge = [...host.querySelectorAll("button")].find((button) =>
      (button.textContent ?? "").startsWith(MISSING_FILES_BADGE_LABEL),
    );
    if (!badge) throw new Error("no missing files badge");

    await userEvent.click(badge);
    expect(useNavStore.getState().page).toBe("package");
    expect(useNavStore.getState().packageRef).toEqual({
      kind: "skill",
      name: "gh",
      identity: "recorded",
      scope: VG,
    });
  });
});

// A chip or a place clicked on a Library row asks for a view of the Library
// while the Library is already on screen. Nothing remounts, so a handoff
// left in the nav store would be read by no one: the table, the filter
// strip and the scope pills all have to move now.
describe("narrowing the Library from a row it is already showing", () => {
  const codexHere = {
    ...installed(VG),
    name: "orch",
    harness: "codex",
    path: "/work/vg/.codex/skills/orch",
  } as unknown as ObservedItem;

  beforeEach(() => {
    vi.spyOn(useProvenanceStore.getState(), "load").mockResolvedValue();
    vi.spyOn(useEditorStore.getState(), "loadAll").mockResolvedValue();
    useEditorStore.setState({ saved: {} });
    useUpdatesStore.setState({ rows: [], read: READ_LANDED });
    useScanStore.setState({
      result: {
        harnesses: [],
        items: [installed(HYPR), codexHere],
        missingProjects: [],
        readProjects: [],
        warnings: [],
      } as never,
    });
    useLibraryViewStore.setState({ ...NO_FILTERS });
    useNavStore.setState({
      page: "library",
      libraryScope: "all",
      libraryFilter: null,
      search: "",
    });
  });

  const rowNames = (host: HTMLElement) =>
    [...host.querySelectorAll("tbody tr td:first-child")].map((cell) =>
      cell.querySelector("button")?.textContent?.trim(),
    );

  const named = (host: HTMLElement, label: string) => {
    const found = [...host.querySelectorAll("button")].find(
      (button) =>
        button.textContent === label ||
        button.getAttribute("aria-label") === label,
    );
    if (!found) throw new Error(`no control named ${label}`);
    return found;
  };

  it("narrows the table on screen from a harness chip", async () => {
    const host = mount(<InstalledView />);
    expect(rowNames(host)).toEqual(["gh", "orch"]);

    await userEvent.click(named(host, "Codex"));

    expect(rowNames(host)).toEqual(["orch"]);
    expect(useLibraryViewStore.getState().harness).toBe("codex");
    // Nothing is left for a later visit to pick up as its own link.
    expect(useNavStore.getState().libraryFilter).toBeNull();
    expect(useNavStore.getState().page).toBe("library");
  });

  it("narrows the table on screen from the place on a row", async () => {
    const host = mount(<InstalledView />);
    expect(rowNames(host)).toEqual(["gh", "orch"]);

    await userEvent.click(named(host, "hyprtrade"));

    expect(rowNames(host)).toEqual(["gh"]);
    expect(useNavStore.getState().libraryScope).toEqual({
      project: "/work/hyprtrade",
    });
    expect(useNavStore.getState().libraryFilter).toBeNull();
  });

  // The control: the same request from another page is still a navigation,
  // and still hands the view over for the Library to adopt on arrival.
  it("still hands the view over when the Library is not the page", () => {
    useNavStore.setState({ page: "harnesses", libraryFilter: null });
    openLibraryAt({ harness: "codex" });
    const nav = useNavStore.getState();
    expect(nav.page).toBe("library");
    expect(nav.libraryFilter).toEqual({ harness: "codex" });
    // Applied by the Library on mount, not by the call itself.
    expect(useLibraryViewStore.getState().harness).toBe("any");
  });
});

// A marketplace source is an alias declared at one place. A row that read
// the alias from one project's record and the scope from another's
// installation would open a subscription that exists at neither.
describe("the marketplace a Library row came from", () => {
  const fromKit = {
    ...installed(HYPR),
    path: "/work/hyprtrade/.claude/skills/gh",
  } as unknown as ObservedItem;
  const fromOther = {
    ...installed(VG),
    path: "/work/vg/.claude/skills/gh",
  } as unknown as ObservedItem;

  // What the records say about one of those copies. Both places record the
  // same package, which is what puts the two copies on one row; the alias
  // below is declared at hyprtrade and nowhere else.
  const recorded = (item: ObservedItem, origin: Origin): ProvenanceRow => ({
    scope: item.scope,
    kind: item.kind,
    name: item.name,
    harness: item.harness,
    at: observedAt(item),
    summary: null,
    package: { kind: "skill", name: "gh" },
    origin,
  });

  beforeEach(() => {
    vi.spyOn(useProvenanceStore.getState(), "load").mockResolvedValue();
    vi.spyOn(useEditorStore.getState(), "loadAll").mockResolvedValue();
    useEditorStore.setState({ saved: {} });
    useUpdatesStore.setState({ rows: [], read: READ_LANDED });
    useScanStore.setState({
      result: {
        harnesses: [],
        // Installation order puts VG first, so a row reading the scope off
        // the group's first installation would answer VG.
        items: [fromOther, fromKit],
        missingProjects: [],
        readProjects: [],
        warnings: [],
      } as never,
    });
    // Provenance answers in its own order, and the row it answers with is
    // hyprtrade's: the alias is declared there and nowhere else, while the
    // group's first installation is vg's.
    joinAnswered([
      recorded(fromKit, {
        origin: "marketplace",
        source: "kit",
        repo: "vg/kit",
      }),
      recorded(fromOther, { origin: "own", forkedFrom: null, source: "local" }),
    ]);
    useLibraryViewStore.setState({ ...NO_FILTERS });
    useNavStore.setState({
      page: "library",
      libraryScope: "all",
      libraryFilter: null,
      marketplaceRef: null,
      search: "",
    });
  });

  it("opens it at the place that declared the alias, not the group's first", async () => {
    const host = mount(<InstalledView />);
    const from = [...host.querySelectorAll("button")].find(
      (button) => button.textContent === "kit",
    );
    if (!from) throw new Error("the marketplace is not a control");
    await userEvent.click(from);

    const nav = useNavStore.getState();
    expect(nav.page).toBe("marketplaceDetail");
    expect(nav.marketplaceRef).toEqual({
      by: "subscription",
      scope: HYPR,
      source: "kit",
    });
  });

  // The control: a package the reader wrote names no marketplace, so the
  // cell stays text and there is nothing to open.
  it("leaves a row with no marketplace unopenable", () => {
    joinAnswered([
      recorded(fromKit, { origin: "own", forkedFrom: null, source: "local" }),
      recorded(fromOther, { origin: "own", forkedFrom: null, source: "local" }),
    ]);
    const host = mount(<InstalledView />);
    const from = [...host.querySelectorAll("button")].find(
      (button) => button.textContent === "Your own",
    );
    expect(from).toBeUndefined();
    expect(host.textContent).toContain("Your own");
  });
});

// A project with nothing in it is not a table hiding rows behind a
// filter: the way out is to install something there, and the place is
// already named by the narrowing the reader set.
describe("the Library narrowed to a place that has nothing", () => {
  beforeEach(() => {
    vi.spyOn(useProvenanceStore.getState(), "load").mockResolvedValue();
    vi.spyOn(useEditorStore.getState(), "loadAll").mockResolvedValue();
    useEditorStore.setState({ saved: {} });
    useUpdatesStore.setState({ rows: [], read: READ_LANDED });
    useSettingsStore.setState({
      settings: { projects: [VG.root, HYPR.root] } as never,
    });
    useLibraryViewStore.setState(NO_FILTERS);
    useScanStore.setState({
      scanning: false,
      error: null,
      result: {
        items: [installed(HYPR)],
        harnesses: [],
        warnings: [],
        missingProjects: [],
        readProjects: [],
      },
    });
  });

  it("offers to install here, carrying the place into the browse", async () => {
    useNavStore.setState({
      libraryScope: { project: VG.root },
      search: "",
      libraryFilter: null,
      installInto: null,
    });
    const host = mount(<InstalledView />);

    expect(host.textContent).toContain(nothingInstalledIn("vg"));
    const add = [...host.querySelectorAll("button")].find(
      (one) => one.textContent === addPackagesTo("vg"),
    );
    if (!add) throw new Error("no add-packages button in the empty table");
    await userEvent.click(add);

    expect(useNavStore.getState().page).toBe("marketplaces");
    expect(useNavStore.getState().installInto).toEqual(VG);
  });

  // With a filter on top, an empty table is what that filter is hiding.
  // Offering to install would name a place that may already hold plenty.
  it("offers to clear the filter instead when one is narrowing the table", () => {
    useNavStore.setState({
      libraryScope: { project: HYPR.root },
      search: "nothing-matches-this",
      libraryFilter: null,
    });
    const host = mount(<InstalledView />);

    expect(host.textContent).not.toContain(nothingInstalledIn("hyprtrade"));
    expect(host.textContent).toContain("Clear filters");
  });
});

// The reported defect: one hook installed for several tools stood as a
// row per tool, because each tool stores it under a spelling of its own.
// The join says which of those are one package, and the table shows that.
describe("one package several tools store differently", () => {
  const at = (
    harness: HarnessId,
    kind: ItemKind,
    name: string,
    path: string,
  ): ObservedItem =>
    observed({
      kind,
      name,
      harness,
      scope: VG,
      path,
      fileState: { state: "file" },
      enabled: true,
      origin: null,
      summary: null,
      action: null,
      tags: [],
      modifiedAt: null,
      vendor: null,
    });

  const items = [
    at(
      "claude",
      "hook",
      "PreToolUse:Bash:block-bare-cd",
      "/work/vg/.claude/settings.json",
    ),
    at(
      "cursor",
      "agent",
      "safety-block-bare-cd",
      "/work/vg/.cursor/rules/safety-block-bare-cd.mdc",
    ),
    // Nobody's record accounts for this one, and it carries the name a
    // generated rule takes: it is a row of its own or the table is
    // claiming an owner it has no evidence for.
    at(
      "cursor",
      "agent",
      "safety-block-argv-kill",
      "/work/vg/.cursor/rules/safety-block-argv-kill.mdc",
    ),
  ];

  // One row per observation, each naming the file it was read from — the
  // join answers per file, as the scan sees them.
  const row = (item: ObservedItem) => ({
    scope: item.scope,
    kind: item.kind,
    name: item.name,
    harness: item.harness,
    at: item.at,
    origin: { origin: "marketplace", source: "kendex", repo: "vg/kendex" },
    summary: null,
    package: { kind: "hook", name: "block-bare-cd" },
  });

  beforeEach(() => {
    vi.spyOn(useEditorStore.getState(), "loadAll").mockResolvedValue();
    useEditorStore.setState({ saved: {} });
    useUpdatesStore.setState({ rows: [], read: READ_LANDED });
    useProvenanceStore.setState({
      rows: [
        row(items[0]),
        row(items[1]),
        {
          scope: VG,
          kind: "agent",
          name: "safety-block-argv-kill",
          harness: "cursor",
          at: items[2].at,
          origin: { origin: "unmanaged" },
          summary: null,
          package: null,
        },
      ] as never,
      loaded: true,
      answeredFor: 0,
      read: READ_LANDED,
    });
    useScanStore.setState({
      result: {
        harnesses: [],
        items,
        missingProjects: [],
        readProjects: [],
        warnings: [],
      } as never,
    });
    useLibraryViewStore.setState({ ...NO_FILTERS });
    useNavStore.setState({ libraryScope: "all", search: "" });
  });

  const harnessesOf = (host: HTMLElement, row: number) =>
    [
      ...(host
        .querySelectorAll("tbody tr")
        [row].querySelectorAll("td")[3]
        ?.querySelectorAll("[aria-label]") ?? []),
    ].map((mark) => mark.getAttribute("aria-label"));

  const cells = (host: HTMLElement) =>
    [...host.querySelectorAll("tbody tr")].map((tr) =>
      [...tr.querySelectorAll("td")].map((td) => td.textContent?.trim() ?? ""),
    );

  it("shows the package once, under its own name, kind and marketplace", () => {
    const host = mount(<InstalledView />);
    const rows = cells(host);
    expect(rows).toHaveLength(2);
    // Sorted on the group key, which puts an observation before a package.
    const [stray, managed] = rows;
    expect(managed[0]).toContain("block-bare-cd");
    expect(managed[1]).toBe("Hook");
    expect(managed[5]).toBe("kendex");
    // Both tools on the one row, each mark once. A mark is a logo, so the
    // tool it stands for is read off the label it carries.
    expect(harnessesOf(host, 1)).toEqual(["Claude Code", "Cursor"]);
    // The rule nobody recorded keeps its own row and its own answer.
    expect(stray[0]).toContain("safety-block-argv-kill");
    expect(stray[1]).toBe("Agent");
    expect(stray[5]).toBe("Not managed");
  });

  it("counts the package once and opens it by the identity it shows", () => {
    const opened: unknown[] = [];
    useNavStore.setState({
      libraryScope: "all",
      search: "",
      goToPackage: ((ref: unknown) => opened.push(ref)) as never,
    });
    const host = mount(<InstalledView />);
    expect(host.textContent).toContain("2 items");
    const names = [...host.querySelectorAll("tbody tr td:first-child button")];
    (names[1] as HTMLButtonElement).click();
    // ...and the row nothing recorded opens as itself.
    (names[0] as HTMLButtonElement).click();
    // The link states which of the two things wearing this kind and name
    // it meant, so the page cannot open the other one.
    expect(opened).toEqual([
      { kind: "hook", name: "block-bare-cd", scope: VG, identity: "recorded" },
      {
        kind: "agent",
        name: "safety-block-argv-kill",
        scope: VG,
        identity: "observed",
        // A row nothing recorded is named by the file it reads: its kind
        // and name are not its identity.
        at: "/work/vg/.cursor/rules/safety-block-argv-kill.mdc",
      },
    ]);
  });
});

// A hook is a command in a tool's settings file. What the row says about it
// is the words its author wrote, which the join carries; the command is not
// a description of anything and never stands in for one.
describe("what a Library row says a package is for", () => {
  const WORDS = "Stops a command whose whole line is a cd.";
  const COMMAND = 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/block-bare-cd.sh"';

  const item = observed({
    kind: "hook",
    name: "PreToolUse:Bash:block-bare-cd",
    harness: "claude",
    scope: VG,
    path: "/work/vg/.claude/settings.json",
    fileState: { state: "config-entry" },
    enabled: true,
    origin: null,
    // The scan reads a registration, not a package: the words reach the
    // row through the join, which asked the package the records name.
    summary: null,
    action: COMMAND,
    tags: [],
    modifiedAt: null,
    vendor: null,
  });

  beforeEach(() => {
    vi.spyOn(useEditorStore.getState(), "loadAll").mockResolvedValue();
    useEditorStore.setState({ saved: {} });
    useUpdatesStore.setState({ rows: [], read: READ_LANDED });
    useProvenanceStore.setState({
      rows: [
        {
          scope: VG,
          kind: item.kind,
          name: item.name,
          harness: item.harness,
          at: item.at,
          origin: {
            origin: "marketplace",
            source: "kendex",
            repo: "vg/kendex",
          },
          summary: WORDS,
          package: { kind: "hook", name: "block-bare-cd" },
        },
      ] as never,
      loaded: true,
      answeredFor: 0,
      read: READ_LANDED,
    });
    useScanStore.setState({
      result: {
        harnesses: [],
        items: [item],
        missingProjects: [],
        warnings: [],
      } as never,
    });
    useLibraryViewStore.setState({ ...NO_FILTERS });
    useNavStore.setState({ libraryScope: "all", search: "" });
  });

  it("shows the author's words and never the command", () => {
    const host = mount(<InstalledView />);
    const name = host.querySelector("tbody tr td:first-child");
    expect(name?.textContent).toContain(WORDS);
    expect(host.textContent, "a command is not a description").not.toContain(
      COMMAND,
    );
  });

  /** The packages a search left on screen. An empty table still draws a
   *  row, carrying the way out of the narrowing rather than a package. */
  const named = (search: string) => {
    useNavStore.setState({ libraryScope: "all", search });
    const host = mount(<InstalledView />);
    return [...host.querySelectorAll("tbody tr")]
      .filter((row) => row.querySelectorAll("td").length > 1)
      .map((row) => row.querySelector("td button")?.textContent);
  };

  it("is found by searching those words, as the marketplace finds it", () => {
    expect(named("whole line")).toEqual(["block-bare-cd"]);
    expect(
      named("block-bare-cd.sh"),
      "the command is not searchable text about the package",
    ).toEqual([]);
  });
});

// The read that says which installations are one package answers on its own.
// A first read still on its way, a read that failed with nothing kept, and a
// read that failed over rows it had are three answers, and only the last has
// anything to draw.
describe("the Library while the identity read has not answered", () => {
  const items = [installed(VG)];

  const arrange = (provenance: {
    rows: never[];
    loaded: boolean;
    /** Which scan the rows answer about, null where none has been
     *  answered for. The fixtures set the scan store directly, which
     *  leaves its generation at 0. */
    answeredFor: number | null;
    read: ReadState;
    reload?: () => Promise<void>;
  }) => {
    vi.spyOn(useEditorStore.getState(), "loadAll").mockResolvedValue();
    useEditorStore.setState({ saved: {} });
    useUpdatesStore.setState({ rows: [], read: READ_LANDED });
    useProvenanceStore.setState(provenance as never);
    useScanStore.setState({
      result: {
        harnesses: [],
        items,
        missingProjects: [],
        readProjects: [],
        warnings: [],
      } as never,
    });
    useLibraryViewStore.setState({ ...NO_FILTERS });
    useNavStore.setState({ libraryScope: "all", search: "" });
    return mount(<InstalledView />);
  };

  const skeleton = (host: HTMLElement) =>
    host.querySelector('[data-slot="skeleton"]') !== null;
  /** Package rows, not the skeleton's placeholder rows: only a real row
   *  carries the button that opens its package. */
  const rows = (host: HTMLElement) =>
    host.querySelectorAll("tbody tr td:first-child button").length;

  // Not merely a skeleton alongside the rows: grouped with an empty index
  // every row is an installation wearing a package's clothes, which is the
  // duplication this page exists to stop.
  it("draws no rows at all while the first read is on its way", () => {
    const host = arrange({
      rows: [],
      loaded: false,
      answeredFor: null,
      read: READ_PENDING,
    });
    expect(skeleton(host)).toBe(true);
    expect(rows(host)).toBe(0);
    expect(host.textContent).not.toContain(PACKAGES_CHECK_FAILED_TITLE);
  });

  // A skeleton here would say "still checking" for the rest of the session:
  // nothing re-triggers the read but another scan.
  it("says the read failed, offers it again, and counts nothing", () => {
    const reload = vi.fn().mockResolvedValue(undefined);
    const host = arrange({
      rows: [],
      loaded: false,
      answeredFor: null,
      read: readFailed("no lock"),
      reload,
    });
    expect(skeleton(host)).toBe(false);
    expect(host.textContent).toContain(PACKAGES_CHECK_FAILED_TITLE);
    expect(host.textContent).toContain("no lock");
    // Not one row: every row drawn now would be an installation under a
    // heading that says package.
    expect(rows(host)).toBe(0);
    expect(host.textContent).toContain("—");
    const retry = [...host.querySelectorAll("button")].find(
      (button) => button.textContent === TRY_AGAIN_LABEL,
    );
    if (!retry) throw new Error("no Try again button");
    retry.click();
    expect(reload).toHaveBeenCalled();
  });

  it("keeps the last answer it had, headed as unconfirmed", () => {
    const host = arrange({
      rows: [],
      loaded: true,
      answeredFor: 0,
      read: readFailed("no lock"),
    });
    expect(rows(host)).toBe(1);
    expect(host.textContent).toContain(PACKAGES_UNCONFIRMED_TITLE);
    expect(host.textContent).not.toContain(PACKAGES_CHECK_FAILED_TITLE);
  });

  // A read that failed after a scan has settled: it will not answer for
  // that scan on its own. Its rows answer about an EARLIER scan, though,
  // so they are not drawn beside the observations now on screen — grouping
  // the two would show a state that never existed and call it the last
  // kendex could check. The failure is said instead, with its retry.
  it("says so rather than mixing an older answer with this scan", () => {
    const host = arrange({
      rows: [],
      loaded: true,
      // Answered about the scan before the one on screen.
      answeredFor: -1,
      read: readFailed("no lock"),
    });
    expect(skeleton(host)).toBe(false);
    expect(rows(host)).toBe(0);
    expect(host.textContent).toContain("no lock");
    expect(host.textContent).toContain("—");
  });
});

// The table's room is the page's, and the Library draws eight columns: at
// the 900x600 minimum window kendex opens, all eight used to run off the
// right edge, taking the health dot with them — so the reader at the
// supported minimum could not see which package needed attention.
describe("the columns a narrow Library table keeps", () => {
  /** The room the table has at the 900px minimum window: the window less
   *  the sidebar and its border (`w-56` plus `border-r`, `sidebar.tsx`,
   *  which carries no responsive variant), the page gutters (`PAGE_GUTTER`
   *  is `px-5 md:px-8 2xl:px-12`, and a 900px viewport is past Tailwind's
   *  768px `md`, so `px-8`), the scroller's own `pr-2`, and the lane its
   *  `[scrollbar-gutter:stable]` reserves — measured at 15px in Chromium,
   *  which is what Windows runs. That last term is zero on an engine whose
   *  scrollbars overlay, making the room 603 there; this takes the tighter
   *  of the two, since a budget has to fit the narrower room to fit both.
   *  The table draws the same four columns at either, the next rung up
   *  being 752. */
  const AT_MINIMUM_WINDOW = 900 - 225 - 64 - 8 - 15;

  const heads = (host: HTMLElement): string[] =>
    [...host.querySelectorAll("thead th")].map(
      (cell) => cell.textContent?.trim() ?? "",
    );

  /** The cells of the first package row. The headers are the view's and the
   *  cells are the row's, so a table that agrees with itself has to be read
   *  on both sides: drop a conditional from one and the columns misalign
   *  while the other still reads correctly. */
  const cells = (host: HTMLElement): HTMLTableCellElement[] => [
    ...host.querySelectorAll<HTMLTableCellElement>("tbody tr:first-child td"),
  ];

  beforeEach(() => {
    vi.spyOn(useEditorStore.getState(), "loadAll").mockResolvedValue();
    useEditorStore.setState({ saved: {} });
    useUpdatesStore.setState({ rows: [], read: READ_LANDED });
    useScanStore.setState({
      result: {
        harnesses: [],
        items: [installed(VG)],
        missingProjects: [],
        warnings: [],
      } as never,
    });
    joinAnswered();
    useLibraryViewStore.setState({ ...NO_FILTERS });
    useNavStore.setState({ libraryScope: "all", search: "" });
  });

  it("keeps Status at the minimum window and every column at a wide one", () => {
    roomIs(AT_MINIMUM_WINDOW);
    const narrow = mount(<InstalledView />);
    expect(heads(narrow)).toEqual(["Name", "Type", "Where", "Status"]);
    // The row draws what the header declares, and Status is the last of
    // them: four cells, the fourth carrying the dot's own reading.
    expect(cells(narrow)).toHaveLength(4);
    expect(cells(narrow)[3].textContent).toContain("Active");

    roomIs(1400);
    const wide = mount(<InstalledView />);
    expect(heads(wide)).toEqual([
      "Name",
      "Type",
      TAGS_ROW_LABEL,
      "Harnesses",
      "Where",
      "From",
      "Updated",
      "Status",
    ]);
    expect(cells(wide)).toHaveLength(8);
    expect(cells(wide)[7].textContent).toContain("Active");
  });

  // A project basename is the reader's, and the table lays out
  // automatically, so an uncapped Where cell took whatever its content
  // asked for and carried the columns after it off the right edge.
  it("keeps the row to its columns when a project name is long", () => {
    const LONG = "/work/kendex-marketplace-integration";
    const place: Scope = { scope: "project", root: LONG };
    useScanStore.setState({
      result: {
        harnesses: [],
        items: [installed(place)],
        missingProjects: [],
        warnings: [],
      } as never,
    });
    joinAnswered();
    roomIs(AT_MINIMUM_WINDOW);
    const host = mount(<InstalledView />);

    const row = cells(host);
    expect(row).toHaveLength(4);
    expect(row[3].textContent, "Status is still the last cell").toContain(
      "Active",
    );
    // Capped on screen, whole on the cell: the reader loses no part of
    // which project this is.
    expect(row[2].textContent).toContain("kendex-marketplace-integration");
    expect(row[2].getAttribute("title")).toBe(LONG);
  });

  // The two cases above hold the ends of the ladder. These hold its rungs:
  // which column comes back first is the judgement this issue asked for,
  // and a reordered BUDGET.order or a changed cost would leave both ends
  // right and every width between them wrong. Each width is the rung's own
  // — the sum of the kept columns and everything afforded up to it — so a
  // cost that moves takes its rung with it.
  it("brings each column back at its own width, in its own order", () => {
    const RUNGS = [
      { room: 752, back: ["Harnesses"] },
      { room: 880, back: ["Harnesses", "From"] },
      { room: 992, back: ["Harnesses", "From", "Updated"] },
      { room: 1152, back: ["Harnesses", "From", "Updated", TAGS_ROW_LABEL] },
    ];
    expect(RUNGS).toHaveLength(4);
    for (const { room, back } of RUNGS) {
      roomIs(room);
      const host = mount(<InstalledView />);
      // Drawn in the header's own order, which is not the restore order:
      // a column comes back where the table draws it, not at the end.
      const drawn = heads(host);
      expect(drawn, `${room}px`).toEqual(
        [
          "Name",
          "Type",
          TAGS_ROW_LABEL,
          "Harnesses",
          "Where",
          "From",
          "Updated",
          "Status",
        ].filter(
          (head) =>
            ["Name", "Type", "Where", "Status"].includes(head) ||
            back.includes(head),
        ),
      );
      // One rung below its own width the newest column is not there yet.
      roomIs(room - 1);
      expect(heads(mount(<InstalledView />)), `${room - 1}px`).toEqual(
        drawn.filter((head) => head !== back[back.length - 1]),
      );
    }
  });

  // The table draws two other states, and both changed here: the skeleton
  // now draws the columns the table draws, and the empty row spans the
  // columns on screen rather than a fixed eight. A reader whose scan has
  // not answered, or whose filters match nothing, sees one of them at the
  // minimum window like any other row.
  it("draws the skeleton to the columns on screen", () => {
    useProvenanceStore.setState({
      rows: [],
      loaded: false,
      answeredFor: null,
      read: READ_PENDING,
    });
    roomIs(AT_MINIMUM_WINDOW);
    const narrow = mount(<InstalledView />);
    expect(narrow.querySelector('[data-slot="skeleton"]')).not.toBeNull();
    expect(cells(narrow)).toHaveLength(4);

    roomIs(1400);
    expect(cells(mount(<InstalledView />))).toHaveLength(8);
  });

  it("spans the empty row across the columns on screen", () => {
    useScanStore.setState({
      result: {
        harnesses: [],
        items: [],
        missingProjects: [],
        warnings: [],
      } as never,
    });
    joinAnswered();
    roomIs(AT_MINIMUM_WINDOW);
    const narrow = mount(<InstalledView />);
    const empty = cells(narrow);
    expect(empty).toHaveLength(1);
    expect(empty[0].colSpan).toBe(4);

    roomIs(1400);
    expect(cells(mount(<InstalledView />))[0].colSpan).toBe(8);
  });

  // Every Badge is shrink-0 and whitespace-nowrap, so a strip of them that
  // cannot wrap set the name column's min-content width, which beats the
  // cell's max-width under an automatic table layout. A fork badge names
  // its place, and `placeName` falls back to a whole root where two places
  // end alike, so two of those made the column as wide as they pleased.
  it("keeps the row to its columns when a package is forked in long places", () => {
    const PLACES = [
      "/work/kendex-marketplace-integration/apps/web",
      "/home/me/experiments/kendex-marketplace-integration/apps/web",
    ];
    const forked = {
      schema: 1,
      install: {},
      forks: { skill: { gh: { source: "local", "forked-at": "2026-01-01" } } },
    };
    useScanStore.setState({
      result: {
        harnesses: [],
        items: PLACES.map((root) => installed({ scope: "project", root })),
        missingProjects: [],
        warnings: [],
      } as never,
    });
    useEditorStore.setState({
      saved: Object.fromEntries(PLACES.map((root) => [root, forked as never])),
    });
    joinAnswered(
      PLACES.map((root) => ({
        scope: { scope: "project", root },
        kind: "skill" as const,
        name: "gh",
        harness: "claude" as const,
        at: installed({ scope: "project", root }).path,
        origin: { origin: "own" as const, forkedFrom: null, source: "local" },
        summary: null,
        package: { kind: "skill" as const, name: "gh" },
      })) as never,
    );
    roomIs(AT_MINIMUM_WINDOW);
    const host = mount(<InstalledView />);

    const row = cells(host);
    // Two badges, each naming a place long enough that the pair used to
    // set the column's width on their own.
    const badges = [...row[0].querySelectorAll("button")].filter((b) =>
      (b.textContent ?? "").startsWith(FORKED_BADGE_LABEL),
    );
    expect(badges).toHaveLength(2);
    // Clipped by CSS, never by the string: what a screen reader reads is
    // still the whole place.
    for (const badge of badges)
      expect(badge.textContent).toContain("kendex-marketplace-integration");

    expect(row).toHaveLength(4);
    expect(row[3].textContent, "Status is still the last cell").toContain(
      "Active",
    );
  });
});
