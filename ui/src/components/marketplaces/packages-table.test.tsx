// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type {
  AvailablePackage,
  Catalog,
  DirectoryRow,
  Finding,
  MarketplaceRow,
  PackageSafety,
  Scope,
} from "@/bindings";
import type { PackageEntry } from "@/components/marketplaces/package-row";
import {
  EVERYTHING_HERE_LABEL,
  INSTALL_ACTION,
  installSelectedLabel,
  justThisLabel,
  selectedLabel,
} from "@/lib/copy-install";
import {
  INSTALLED_IN_HEADING,
  PACKAGE_STATE_UNKNOWN,
  SUBSCRIBE_TO_INSTALL_LABEL,
} from "@/lib/copy-marketplaces";
import {
  SAFETY_CAVEAT,
  SAFETY_DOT_UNCHECKED,
  safetyDotWords,
} from "@/lib/copy-safety";
import { placesKey } from "@/lib/installed-places";
import { READ_LANDED } from "@/lib/read-state";
import { useCommunityStore } from "@/stores/community";
import { useInstallFlow } from "@/stores/install-flow";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { subscription } from "@/stores/marketplaces-shared";
import { useNavStore } from "@/stores/nav";
import { safetyKey } from "@/stores/preinstall-safety";
import { useProvenanceStore } from "@/stores/provenance";
import { mount as mountTree, roomIs } from "@/test/dom";
import { PackagesTable } from "./packages-table";

// Static rendering reads a zustand store's initial snapshot, so the score
// store's hook is wrapped to let each test seed the row's score.
const stub = vi.hoisted(() => ({ scores: {} as Record<string, unknown> }));
vi.mock("@/stores/preinstall-safety", async (importOriginal) => {
  const mod =
    await importOriginal<typeof import("@/stores/preinstall-safety")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.usePreinstallSafety.getState(),
      scores: stub.scores,
      // A mounted row runs the effect that queues a score, and there is no
      // backend behind these tests to answer it.
      want: () => {},
    };
    return selector ? selector(state) : state;
  };
  return {
    ...mod,
    usePreinstallSafety: Object.assign(hook, mod.usePreinstallSafety),
  };
});

const catalog = subscription({ scope: "global" }, "kendex");

const row: AvailablePackage = {
  kind: "skill",
  name: "gh",
  description: null,
  summary: null,
  tags: [],
  bundles: [],
  dependencies: { required: [], optional: [] },
  state: "available",
  collision: null,
  updatedAt: null,
};

const FINDING: Finding = {
  rule: "dangerous-commands",
  severity: "high",
  location: "SKILL.md",
  line: 3,
  message: "runs a shell command that deletes files without asking",
  remediation: "scope the command to a specific path, or drop it",
};

const scored = (score: number, findings: Finding[] = []): PackageSafety => ({
  kind: "skill",
  name: "gh",
  findings,
  safety: { score, deductions: [] },
  quality: null,
  skipped: [],
  notes: [],
  contentHash: "abc",
  ruleset: 1,
  fromCache: false,
});

const render = (safety: PackageSafety | null) => {
  stub.scores = safety ? { [safetyKey(catalog, "skill", "gh")]: safety } : {};
  return renderToStaticMarkup(
    <PackagesTable
      entries={[{ catalog, row, recordsUnreadable: false }]}
      showMarketplace={false}
    />,
  );
};

// What the dot's words are attached to. A tooltip popup is portalled and
// only mounts once open, so the trigger's own contents are the whole of
// what a reader gets without a pointer.
const trigger = (html: string): string =>
  html.match(
    /<button[^>]*data-slot="tooltip-trigger"[^>]*>(.*?)<\/button>/,
  )?.[1] ?? "";

// The description is the agent's load trigger; the row is for a person, so
// it shows the summary and never the trigger beside it.
describe("the line under the package name", () => {
  it("is the summary, not the description", () => {
    stub.scores = {};
    const html = renderToStaticMarkup(
      <PackagesTable
        entries={[
          {
            catalog,
            recordsUnreadable: false,
            row: {
              ...row,
              description: "Load to work a pull request.",
              summary: "Threads, reviews, CI logs, merges.",
            },
          },
        ]}
        showMarketplace={false}
      />,
    );
    expect(html).toContain("Threads, reviews, CI logs, merges.");
    expect(html).not.toContain("Load to work a pull request.");
  });
});

describe("the safety dot in the packages list", () => {
  it("carries score, severity and missing-result words beside the install", () => {
    const rows = [
      {
        name: "checked without findings",
        safety: scored(100),
        shown: ["100/100.", SAFETY_CAVEAT],
        install: true,
        accessible: true,
        unchecked: false,
      },
      {
        name: "checked with findings",
        safety: scored(60, [FINDING]),
        shown: ["60/100.", SAFETY_CAVEAT],
        install: false,
        accessible: false,
        unchecked: false,
      },
      {
        name: "worst severity",
        safety: scored(40, [FINDING, { ...FINDING, severity: "critical" }]),
        shown: ["Serious · 40/100."],
        install: false,
        accessible: false,
        unchecked: false,
      },
      {
        name: "no result landed",
        safety: null,
        shown: ["Not checked yet.", SAFETY_CAVEAT, SAFETY_DOT_UNCHECKED],
        install: true,
        accessible: false,
        unchecked: true,
      },
    ];
    expect(rows).toHaveLength(4);
    for (const row of rows) {
      const html = render(row.safety);
      for (const words of row.shown)
        expect(trigger(html), row.name).toContain(words);
      if (row.install) expect(html, row.name).toContain(">Install<");
      if (row.accessible) {
        expect(trigger(html)).toContain(
          `<span class="sr-only">${safetyDotWords(100, 0, [])}</span>`,
        );
        expect(html.indexOf(SAFETY_CAVEAT)).toBeLessThan(
          html.indexOf(">Install<"),
        );
        expect(html).not.toContain(`title="${safetyDotWords(100, 0, [])}`);
      }
      if (row.unchecked) {
        expect(trigger(html)).not.toMatch(/\d+\/100/);
        expect(html.indexOf(SAFETY_DOT_UNCHECKED)).toBeLessThan(
          html.indexOf(">Install<"),
        );
      }
    }
  });
});

// The activation tests need a live DOM: whether a click reaches the row is a
// question about event propagation, which static markup cannot answer.
const mount = (safety: PackageSafety | null) => {
  stub.scores = safety ? { [safetyKey(catalog, "skill", "gh")]: safety } : {};
  const goToAvailablePackage = vi.fn();
  useNavStore.setState({ goToAvailablePackage });
  const host = mountTree(
    <PackagesTable
      entries={[{ catalog, row, recordsUnreadable: false }]}
      showMarketplace={false}
    />,
  );
  const dot = host.querySelector<HTMLButtonElement>(
    '[data-slot="tooltip-trigger"]',
  );
  if (!dot) throw new Error("no safety trigger rendered");
  return { host, dot, goToAvailablePackage };
};

describe("reading the safety dot", () => {
  it("keeps pointer and keyboard activation on the safety control", async () => {
    const rows = [
      { name: "checked click", safety: scored(60, [FINDING]), event: "click" },
      {
        name: "checked Enter",
        safety: scored(60, [FINDING]),
        event: "{Enter}",
      },
      { name: "checked Space", safety: scored(60, [FINDING]), event: " " },
      { name: "unchecked click", safety: null, event: "click" },
      { name: "unchecked Enter", safety: null, event: "{Enter}" },
    ];
    expect(rows).toHaveLength(5);
    for (const row of rows) {
      const { dot, goToAvailablePackage } = mount(row.safety);
      dot.focus();
      if (row.event === "click") await userEvent.click(dot);
      else await userEvent.keyboard(row.event);
      expect(goToAvailablePackage, row.name).not.toHaveBeenCalled();
    }
  });

  it("still shows the words when the trigger takes focus", () => {
    // The popup is portalled out of the row, so it is the document's to find
    // — and the trigger's own sr-only copy must not stand in for it.
    const { dot } = mount(scored(60, [FINDING]));
    expect(document.querySelector('[data-slot="tooltip-content"]')).toBeNull();
    act(() => dot.focus());
    expect(
      document.querySelector('[data-slot="tooltip-content"]')?.textContent,
    ).toContain(SAFETY_CAVEAT);
  });

  it("does not open the package page from the popup's own words", async () => {
    // The popup is drawn outside the row, but React still routes its clicks
    // through the row, so reading the caveat there must stay a read.
    const { dot, goToAvailablePackage } = mount(scored(60, [FINDING]));
    act(() => dot.focus());
    const popup = document.querySelector<HTMLElement>(
      '[data-slot="tooltip-content"]',
    );
    if (!popup) throw new Error("no tooltip popup rendered");
    await userEvent.click(popup);
    expect(goToAvailablePackage).not.toHaveBeenCalled();
  });

  it("still opens the package page from the rest of the row", async () => {
    const { host, goToAvailablePackage } = mount(scored(60, [FINDING]));
    const name = host.querySelector("td");
    if (!name) throw new Error("no row cell rendered");
    await userEvent.click(name);
    expect(goToAvailablePackage).toHaveBeenCalledWith({
      catalog,
      kind: "skill",
      name: "gh",
    });
  });

  // A row announces its cells rather than an action, so the name is a real
  // control of its own — what a screen reader is told opens the package.
  it("opens the package page from the name itself", async () => {
    const { host, goToAvailablePackage } = mount(scored(60, [FINDING]));
    const name = [...host.querySelectorAll("button")].find(
      (button) => button.textContent === "gh",
    );
    if (!name) throw new Error("the package name is not a control");
    await userEvent.click(name);
    expect(goToAvailablePackage).toHaveBeenCalledWith({
      catalog,
      kind: "skill",
      name: "gh",
    });
  });

  // The keyboard takes the same way in: the row takes focus and Enter
  // opens it.
  it("opens the package page from the row on Enter", async () => {
    const { host, goToAvailablePackage } = mount(scored(60, [FINDING]));
    const row = host.querySelector("tbody tr");
    if (!(row instanceof HTMLElement)) throw new Error("no row rendered");
    expect(row.getAttribute("tabindex")).toBe("0");
    act(() => row.focus());
    await userEvent.keyboard("{Enter}");
    expect(goToAvailablePackage).toHaveBeenCalledWith({
      catalog,
      kind: "skill",
      name: "gh",
    });
  });
});

// The row's own state is cached per package and only refreshed when the
// catalog is read again; the scope's record standing rides on the overview
// row, which every load refreshes. A scope readable when these rows were
// cached, damaged while the app stayed open, is exactly that disagreement —
// and a live Install here reaches the engine and fails on the same record.
describe("a cached row under a scope whose record has since broken", () => {
  it("says not known and offers no install, whatever the cached row claims", () => {
    stub.scores = {};
    const html = renderToStaticMarkup(
      <PackagesTable
        entries={[{ catalog, row, recordsUnreadable: true }]}
        showMarketplace={false}
      />,
    );
    expect(row.state).toBe("available");
    expect(html).toContain(PACKAGE_STATE_UNKNOWN);
    expect(html).not.toContain(">Install<");
  });
});

// A bare repository's table. The row's one action subscribes personally
// and installs in the same click, so which repository and which package it
// hands the store is the whole of what the row contributes — the store
// half is marketplaces-subscribe-install.test.ts.
describe("the row action on a repository nobody subscribes to", () => {
  const repo = "Acme/Kit";
  const repoCatalog: Catalog = { by: "repo", repo };

  const listed: DirectoryRow = {
    repo,
    // The canonical key the offer is decided on, from core rather than the
    // spelling — without it the table cannot tell whether anything already
    // declares the repository, and offers nothing.
    repoKey: "acme/kit",
    repoIdentity: "github.com/acme/kit",
    name: "kit",
    description: null,
    tags: [],
    featured: false,
    packageCount: 1,
    bundleCount: 0,
    subscribed: false,
    packages: [],
    bundles: [],
  };

  const declared: MarketplaceRow = {
    scope: { scope: "global" },
    name: "kit",
    repo,
    repoKey: "acme/kit",
    repoIdentity: "github.com/acme/kit",
    provenance: repo,
    path: null,
    resolvedPath: null,
    rev: null,
    commit: null,
    enabled: false,
    counts: null,
    meta: null,
    mode: null,
    recordsUnreadable: false,
  };

  const draw = (rows: MarketplaceRow[]) => {
    stub.scores = {};
    const subscribeAndInstall = vi.fn(async () => true);
    useCommunityStore.setState({
      directory: { rows: [listed], fetchedAt: "2026-09-02", stale: false },
    });
    useInstallFlow.setState({ ask: null, outcome: null, running: false });
    useMarketplacesStore.setState({
      rows,
      read: READ_LANDED,
      summaries: {},
      subscribeAndInstall,
    });
    const host = mountTree(
      <PackagesTable
        entries={[{ catalog: repoCatalog, row, recordsUnreadable: false }]}
        showMarketplace={false}
      />,
    );
    return { host, subscribeAndInstall };
  };

  const action = (host: HTMLElement) =>
    [...host.querySelectorAll("button")].find(
      (button) => button.textContent === SUBSCRIBE_TO_INSTALL_LABEL,
    );

  it("hands the store this repository and this row's package", async () => {
    const { host, subscribeAndInstall } = draw([]);
    const button = action(host);
    if (!button) throw new Error("no subscribe-and-install button rendered");

    await userEvent.click(button);

    expect(subscribeAndInstall).toHaveBeenCalledWith(repo, [
      { kind: "skill", name: "gh" },
    ]);
  });

  // A subscription that is switched off still declares the repository, so
  // subscribing again is refused as a duplicate. The header carries the one
  // action in that state; the row says only that the package is here.
  it("offers nothing when a switched-off subscription already declares it", () => {
    const { host } = draw([declared]);
    expect(action(host)).toBeUndefined();
    expect(host.textContent).toContain("Available");
  });
});

// One column belongs to a marketplace's own page alone: where each of its
// packages is installed from it. The Last updated column and the sorting
// headers are drawn on both tables deliberately — the cross-marketplace
// list wants them too.
describe("a marketplace's own packages table", () => {
  const dated = (name: string, updatedAt: string | null): PackageEntry => ({
    catalog,
    row: { ...row, name, updatedAt },
    recordsUnreadable: false,
  });

  it("opens sorted by name whatever order the catalog listed in", () => {
    stub.scores = {};
    const html = renderToStaticMarkup(
      <PackagesTable
        entries={[dated("review", null), dated("apply", null)]}
        showMarketplace={false}
        places={new Map()}
      />,
    );
    expect(html).toContain(">apply<");
    expect(html).toContain(">review<");
    expect(html.indexOf(">apply<")).toBeLessThan(html.indexOf(">review<"));
  });

  // Drawn without the places column: it renders the same dash for a package
  // installed nowhere, so with both on the page an assertion on the dash is
  // answered by the wrong cell and says nothing about the date.
  it("dates each row, and says nothing where there is no date to say", () => {
    stub.scores = {};
    const html = renderToStaticMarkup(
      <PackagesTable
        entries={[dated("gh", "2026-08-30T12:00:00+00:00"), dated("zz", null)]}
        showMarketplace={false}
      />,
    );
    expect(html).toContain('title="2026-08-30T12:00:00+00:00"');
    expect(html).toContain("—");
  });

  // The column is the one control on a marketplace page that names the
  // places holding what it offers. The join behind it is
  // `lib/installed-places.ts` and the wording is `lib/place-word.ts`, both
  // tested there; what this settles is that the column draws the count as a
  // control and says nothing for a package installed nowhere.
  it("counts the places holding a package, and says nothing for none", () => {
    stub.scores = {};
    const host = mountTree(
      <PackagesTable
        entries={[dated("gh", null), dated("zz", null)]}
        showMarketplace={false}
        places={
          new Map([
            [
              placesKey("skill", "gh"),
              [
                { scope: "global" } as Scope,
                { scope: "project", root: "/home/me/hyprtrade" } as Scope,
              ],
            ],
          ])
        }
      />,
    );
    // The column's own index, so a column added beside it cannot make this
    // assert about the wrong cell.
    const column = [...host.querySelectorAll("thead th")].findIndex(
      (head) => head.textContent?.trim() === INSTALLED_IN_HEADING,
    );
    const cells = [...host.querySelectorAll("tbody tr")].map(
      (each) => each.children[column]?.textContent ?? "",
    );
    // The personal setup and a project: two places, and not two projects.
    expect(cells).toEqual(["2 places", "—"]);
    expect(
      host.querySelector('button[aria-label="Installed in 2 places"]'),
    ).not.toBeNull();
  });
});

describe("re-sorting a marketplace's packages", () => {
  it("turns the list around when the sorted column is pressed again", async () => {
    stub.scores = {};
    useProvenanceStore.setState({ loaded: true, rows: [] });
    const host = mountTree(
      <PackagesTable
        entries={[
          { catalog, row: { ...row, name: "apply" }, recordsUnreadable: false },
          {
            catalog,
            row: { ...row, name: "review" },
            recordsUnreadable: false,
          },
        ]}
        showMarketplace={false}
        places={new Map()}
      />,
    );
    const names = () =>
      [...host.querySelectorAll("tbody .truncate.font-medium")].map(
        (cell) => cell.textContent,
      );
    expect(names()).toEqual(["apply", "review"]);

    const byName = host.querySelector<HTMLButtonElement>(
      'button[aria-label^="Sorted by Name"]',
    );
    if (!byName) throw new Error("no name sort control rendered");
    await act(async () => {
      await userEvent.click(byName);
    });
    expect(names()).toEqual(["review", "apply"]);
  });
});

// The table's room is the page's, and a marketplace catalogue is wider than
// most windows: below about 1400 logical px the columns used to run off the
// right edge behind an overflow nothing drew, leaving the reader a Name and
// no way to know a Safety or a Status was ever there.
describe("the columns a narrow table keeps", () => {
  /** The columns with a word in them. The first header is the box that
   *  ticks every row, which is a control over the table rather than a
   *  column of it, and it is on screen at every width. */
  const heads = (host: HTMLElement): string[] =>
    [...host.querySelectorAll("thead th")]
      .map((cell) => cell.textContent?.trim() ?? "")
      .filter((word) => word !== "");

  const entry: PackageEntry = {
    catalog,
    recordsUnreadable: false,
    row: { ...row, tags: ["review"], updatedAt: "2026-08-30T12:00:00Z" },
  };

  // Both pages the table serves: the Marketplaces tab, which names each
  // row's marketplace, and one marketplace's own Packages tab, which names
  // where each package landed instead.
  const PAGES = [
    {
      page: "the Marketplaces tab",
      table: <PackagesTable entries={[entry]} showMarketplace />,
      wide: [
        "Name",
        "Kind",
        "For",
        "Marketplace",
        "Last updated",
        "Safety",
        "Status",
      ],
    },
    {
      page: "a marketplace's Packages tab",
      table: (
        <PackagesTable
          entries={[entry]}
          showMarketplace={false}
          places={new Map()}
        />
      ),
      wide: [
        "Name",
        "Kind",
        "For",
        "Last updated",
        "Safety",
        "Installed in",
        "Status",
      ],
    },
  ];

  it("keeps the essential columns and restores each page's declared columns", () => {
    expect(PAGES).toHaveLength(2);
    for (const { page, table, wide } of PAGES) {
      stub.scores = {};
      useProvenanceStore.setState({ loaded: true, rows: [] });
      roomIs(700);
      const host = mountTree(table);
      expect(heads(host), page).toEqual(["Name", "Kind", "Safety", "Status"]);
      expect(trigger(host.innerHTML), page).toContain(SAFETY_DOT_UNCHECKED);
      expect(host.textContent ?? "", page).toContain("Install");
      roomIs(1400);
      const wideHost = mountTree(table);
      expect(heads(wideHost), page).toEqual(wide);
    }
  });
});

// Several rows chosen and one action over them, opening the same guided
// flow a single row's Install opens. The table is the only surface that
// can say what "everything here" means, so it is the one that offers it.
describe("installing from the table", () => {
  const offered = (name: string): PackageEntry => ({
    catalog,
    recordsUnreadable: false,
    row: { ...row, name },
  });
  const installed = (name: string): PackageEntry => ({
    catalog,
    recordsUnreadable: false,
    row: { ...row, name, state: "installed" },
  });

  const draw = (entries: PackageEntry[]) => {
    stub.scores = {};
    useProvenanceStore.setState({ loaded: true, rows: [] });
    useInstallFlow.setState({ ask: null, outcome: null, running: false });
    roomIs(1400);
    return mountTree(
      <PackagesTable
        entries={entries}
        showMarketplace={false}
        places={new Map()}
      />,
    );
  };

  /** The box in a row whose name cell reads `name`. */
  const rowBox = (host: HTMLElement, name: string): HTMLElement => {
    const found = host.querySelector(`[aria-label="Select ${name}"]`);
    if (!(found instanceof HTMLElement)) throw new Error(`no box for ${name}`);
    return found;
  };

  it("offers the ticked rows and everything here as one question", async () => {
    const host = draw([offered("gh"), offered("lint"), offered("deploy")]);

    await userEvent.click(rowBox(host, "gh"));
    await userEvent.click(rowBox(host, "lint"));
    await act(async () => {});

    const action = [...host.querySelectorAll("button")].find(
      (one) => one.textContent === installSelectedLabel(2),
    );
    if (!action) throw new Error("no selection action rendered");
    await userEvent.click(action);
    await act(async () => {});

    const ask = useInstallFlow.getState().ask;
    expect(ask?.subjects.map((one) => one.label)).toEqual([
      selectedLabel(2),
      EVERYTHING_HERE_LABEL,
    ]);
    expect(ask?.subjects[0].groups[0].items).toEqual([
      { kind: "skill", name: "gh" },
      { kind: "skill", name: "lint" },
    ]);
    expect(ask?.subjects[1].count).toBe(3);
  });

  // A row already installed has nothing for this table to install, and a
  // row whose place cannot be read has no state to install against — so
  // neither joins a selection, and "everything here" does not count them.
  it("ticks only the rows it can actually install", async () => {
    const host = draw([offered("gh"), installed("lint")]);

    expect(host.querySelector('[aria-label="Select lint"]')).toBeNull();
    await userEvent.click(rowBox(host, "gh"));
    await act(async () => {});
    const action = [...host.querySelectorAll("button")].find(
      (one) => one.textContent === installSelectedLabel(1),
    );
    if (!action) throw new Error("no selection action rendered");
    await userEvent.click(action);
    await act(async () => {});

    // One row to install and one row ticked is the same answer twice, so
    // "everything here" is not offered beside it.
    expect(
      useInstallFlow.getState().ask?.subjects.map((one) => one.label),
    ).toEqual([selectedLabel(1)]);
  });

  // A row's own Install is the one-package case of the same flow, never a
  // second install path.
  it("opens the flow on one row from that row's own action", async () => {
    const host = draw([offered("gh"), offered("lint")]);

    const install = [...host.querySelectorAll("button")].find(
      (one) => one.textContent === INSTALL_ACTION,
    );
    if (!install) throw new Error("no row action rendered");
    await userEvent.click(install);
    await act(async () => {});

    const ask = useInstallFlow.getState().ask;
    // The whole list, not just its head: a row's action promises one
    // package, so "Everything here" beside it would answer a question the
    // press did not ask and put the whole marketplace one mis-click away.
    expect(ask?.subjects.map((one) => one.label)).toEqual([
      justThisLabel("gh"),
    ]);
    expect(ask?.subjects[0].groups[0].items).toEqual([
      { kind: "skill", name: "gh" },
    ]);
  });
});
