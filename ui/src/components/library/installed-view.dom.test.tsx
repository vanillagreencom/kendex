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
  PACKAGES_CHECK_FAILED_TITLE,
  PACKAGES_UNCONFIRMED_TITLE,
  TRY_AGAIN_LABEL,
} from "@/lib/copy";
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
import { mount } from "@/test/dom";
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
    description: "about gh",
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
      description: null,
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
