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
} from "@/bindings";
import type { PackageEntry } from "@/components/marketplaces/package-row";
import {
  PACKAGE_STATE_UNKNOWN,
  SUBSCRIBE_TO_INSTALL_LABEL,
} from "@/lib/copy-marketplaces";
import {
  SAFETY_CAVEAT,
  SAFETY_DOT_UNCHECKED,
  safetyDotWords,
} from "@/lib/copy-safety";
import { READ_LANDED } from "@/lib/read-state";
import { useCommunityStore } from "@/stores/community";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { subscription } from "@/stores/marketplaces-shared";
import { useNavStore } from "@/stores/nav";
import { safetyKey } from "@/stores/preinstall-safety";
import { useProvenanceStore } from "@/stores/provenance";
import { mount as mountTree } from "@/test/dom";
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
  it("carries the caveat beside the number, since this row installs here", () => {
    const html = render(scored(100));
    expect(html).toContain(">Install<");
    expect(trigger(html)).toContain("100/100.");
    expect(trigger(html)).toContain(SAFETY_CAVEAT);
  });

  it("says the same for a score with findings behind it", () => {
    const html = render(scored(60, [FINDING]));
    expect(trigger(html)).toContain("60/100.");
    expect(trigger(html)).toContain(SAFETY_CAVEAT);
  });

  it("names the worst severity in words, so the colour is never alone", () => {
    const html = render(
      scored(40, [FINDING, { ...FINDING, severity: "critical" }]),
    );
    expect(trigger(html)).toContain("Serious · 40/100.");
  });

  it("puts the words where a keyboard reaches them, not on hover alone", () => {
    // A tab stop before Install, and text in the row rather than a native
    // `title` — which a screen reader may skip and a keyboard never lands on.
    const html = render(scored(100));
    expect(trigger(html)).toContain(
      `<span class="sr-only">${safetyDotWords(100, 0, [])}</span>`,
    );
    expect(html.indexOf(SAFETY_CAVEAT)).toBeLessThan(html.indexOf(">Install<"));
    expect(html).not.toContain(`title="${safetyDotWords(100, 0, [])}`);
  });

  it("says no result has landed, and still claims nothing either way", () => {
    // Scores queue one at a time and a failed read leaves a row without
    // one, so this state is what an installable row often looks like. The
    // caveat has to reach the reader here too, and no score may.
    const html = render(null);
    expect(html).toContain(">Install<");
    expect(trigger(html)).toContain("Not checked yet.");
    expect(trigger(html)).toContain(SAFETY_CAVEAT);
    expect(trigger(html)).toContain(SAFETY_DOT_UNCHECKED);
    expect(trigger(html)).not.toMatch(/\d+\/100/);
    expect(html.indexOf(SAFETY_DOT_UNCHECKED)).toBeLessThan(
      html.indexOf(">Install<"),
    );
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
  it("does not open the package page on a click", async () => {
    const { dot, goToAvailablePackage } = mount(scored(60, [FINDING]));
    await userEvent.click(dot);
    expect(goToAvailablePackage).not.toHaveBeenCalled();
  });

  it("does not open the package page on Enter or Space", async () => {
    // The browser turns both into a click on the button, which is the path
    // the row would otherwise navigate on.
    const { dot, goToAvailablePackage } = mount(scored(60, [FINDING]));
    dot.focus();
    await userEvent.keyboard("{Enter}");
    await userEvent.keyboard(" ");
    expect(goToAvailablePackage).not.toHaveBeenCalled();
  });

  it("does not open it while the score is still being read", async () => {
    const { dot, goToAvailablePackage } = mount(null);
    dot.focus();
    await userEvent.click(dot);
    await userEvent.keyboard("{Enter}");
    expect(goToAvailablePackage).not.toHaveBeenCalled();
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
        subscription={{ catalog, repo: null }}
      />,
    );
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

  // A subscription is a (scope, source, repository), not a name: the same
  // alias can be declared in the personal manifest and in a project's,
  // pointing at different repositories.
  it("names the places holding it, and only from this marketplace", () => {
    stub.scores = {};
    useProvenanceStore.setState({
      loaded: true,
      rows: [
        {
          scope: { scope: "project", root: "/home/me/hyprtrade" },
          kind: "skill",
          name: "gh",
          harness: "claude",
          origin: { origin: "marketplace", source: "kendex", repo: "a/b" },
        },
        // The same package, the same place, a second harness. One place.
        {
          scope: { scope: "project", root: "/home/me/hyprtrade" },
          kind: "skill",
          name: "gh",
          harness: "codex",
          origin: { origin: "marketplace", source: "kendex", repo: "a/b" },
        },
        // The alias this page carries, pointing somewhere else: another
        // subscription's installation, not this marketplace's.
        {
          scope: { scope: "global" },
          kind: "skill",
          name: "gh",
          harness: "claude",
          origin: { origin: "marketplace", source: "kendex", repo: "z/other" },
        },
        // A different source entirely — a collision, which Status says.
        {
          scope: { scope: "project", root: "/home/me/vg" },
          kind: "skill",
          name: "gh",
          harness: "claude",
          origin: { origin: "marketplace", source: "other", repo: "c/d" },
        },
      ],
    });
    // Store state set by a test reaches the component only through a
    // mounted tree: a static render serves the store's initial snapshot.
    const host = mountTree(
      <PackagesTable
        entries={[dated("gh", null)]}
        showMarketplace={false}
        subscription={{ catalog, repo: "a/b" }}
      />,
    );
    const text = host.textContent ?? "";
    expect(text).toContain("hyprtrade");
    expect(text).not.toContain("User level");
    expect(text).not.toContain("vg");
    expect(text.match(/hyprtrade/g)).toHaveLength(1);
  });

  // A path-backed subscription has no repository at all, so a join keyed on
  // the declaration's own `repo` left this column empty for every row of
  // one, always. Both sides carry what the subscription resolved to — a
  // canonical path here — which is what the lock recorded.
  it("names places for a subscription backed by a path", () => {
    stub.scores = {};
    useProvenanceStore.setState({
      loaded: true,
      rows: [
        {
          scope: { scope: "project", root: "/home/me/hyprtrade" },
          kind: "skill",
          name: "gh",
          harness: "claude",
          origin: {
            origin: "marketplace",
            source: "kendex",
            repo: "/home/me/catalogs/kit",
          },
        },
      ],
    });
    const host = mountTree(
      <PackagesTable
        entries={[dated("gh", null)]}
        showMarketplace={false}
        subscription={{ catalog, repo: "/home/me/catalogs/kit" }}
      />,
    );
    expect(host.textContent ?? "").toContain("hyprtrade");
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
        subscription={{ catalog, repo: null }}
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
