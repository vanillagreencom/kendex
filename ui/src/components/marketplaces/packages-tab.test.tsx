// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it } from "vitest";
import type {
  AvailablePackage,
  MarketplaceRow,
  SourceReadRefused,
} from "@/bindings";
import { CHECK_FOR_UPDATES_LABEL } from "@/lib/copy";
import {
  LOCAL_FOLDER_LABEL,
  notDownloadedSourcesLine,
  SEE_PROBLEMS_LABEL,
  unreadableRecordsLine,
  unreadableSourcesLine,
} from "@/lib/copy-marketplaces";
import { marketKey, useMarketplacesStore } from "@/stores/marketplaces";
import { readErrorKey } from "@/stores/marketplaces-shared";
import { usePreinstallSafety } from "@/stores/preinstall-safety";
import { useUpdatesStore } from "@/stores/updates";
import { mount } from "@/test/dom";
import { PackagesTab } from "./packages-tab";

const kit: MarketplaceRow = {
  scope: { scope: "global" },
  name: "kit",
  repo: "Acme/Kit",
  repoKey: "acme/kit",
  repoIdentity: "github.com/acme/kit",
  provenance: null,
  path: null,
  resolvedPath: null,
  rev: null,
  commit: null,
  enabled: true,
  counts: null,
  meta: null,
  mode: null,
  recordsUnreadable: false,
};

const skill = (
  name: string,
  description: string,
  summary: string,
): AvailablePackage => ({
  kind: "skill",
  name,
  description,
  summary,
  tags: [],
  bundles: [],
  dependencies: { required: [], optional: [] },
  state: "available",
  collision: null,
  updatedAt: null,
});

// The description is the agent's load trigger, so a word found there and
// nowhere else is one a person browsing never typed for.
const offered = [
  skill(
    "preflight",
    "Load to run, tune, or debug preflight.",
    "Diff-scoped shellcheck and TOML checks.",
  ),
  skill(
    "worktree",
    "Load to create or repair a git worktree.",
    "Isolated working copies with config symlinks.",
  ),
];

beforeEach(() => {
  useMarketplacesStore.setState({
    rows: [kit],
    packages: { [marketKey(kit.scope, kit.name)]: offered },
    readErrors: {},
    loadPackages: async () => {},
  });
  // A mounted row asks for its safety score, and no backend answers here.
  usePreinstallSafety.setState({ want: () => {} });
  // Whether a place has a readable lock rides on the overview rows. The
  // update read is left empty throughout: nothing here may depend on it.
  useUpdatesStore.setState({ unreadable: [] });
});

const listed = async (needle: string): Promise<string[]> => {
  const host = mount(<PackagesTab />);
  const input = host.querySelector<HTMLInputElement>(
    'input[placeholder="Search packages"]',
  );
  if (!input) throw new Error("no search input rendered");
  if (needle) await userEvent.type(input, needle);
  return [...host.querySelectorAll("tbody tr")].map((row) => nameCell(row));
};

/** What a row leads with, which is its name and the summary under it. The
 *  first cell is the tick a selection is made in, so the name is the one
 *  after it. */
const nameCell = (row: Element): string =>
  row.querySelectorAll("td")[1]?.textContent ?? "";

// Popularity would lead this list if anything the app receives carried
// one; nothing does, so name is the order, and it holds across
// marketplaces rather than restarting inside each one.
describe("ordering the packages list", () => {
  it("sorts by name, not by the order the catalog offered them", async () => {
    useMarketplacesStore.setState({
      packages: {
        [marketKey(kit.scope, kit.name)]: [
          skill("worktree", "", "Isolated working copies."),
          skill("preflight", "", "Diff-scoped checks."),
        ],
      },
    });
    const rows = await listed("");
    expect(rows[0]).toContain("preflight");
    expect(rows[1]).toContain("worktree");
  });

  // The column shows a hook's trailing name, so the order has to be
  // decided on that. Sorting the raw identifier would put
  // "PreToolUse:*:alpha" among the Ps while the reader sees "alpha".
  it("orders a hook by the name the column shows, not its identifier", async () => {
    useMarketplacesStore.setState({
      packages: {
        [marketKey(kit.scope, kit.name)]: [
          skill("middle", "", "A plain package."),
          {
            ...skill("PreToolUse:*:alpha", "", "A hook."),
            kind: "hook",
          },
        ],
      },
    });
    const rows = await listed("");
    expect(rows[0]).toContain("alpha");
    expect(rows[1]).toContain("middle");
  });

  it("interleaves two marketplaces rather than listing one after the other", async () => {
    const tools: MarketplaceRow = {
      ...kit,
      name: "tools",
      repo: "Acme/Tools",
      repoKey: "acme/tools",
    };
    useMarketplacesStore.setState({
      rows: [kit, tools],
      packages: {
        [marketKey(kit.scope, kit.name)]: [
          skill("alpha", "", "From kit."),
          skill("gamma", "", "From kit."),
        ],
        [marketKey(tools.scope, tools.name)]: [
          skill("beta", "", "From tools."),
        ],
      },
    });
    const rows = await listed("");
    // The name cell carries the summary under the name, so the assertion
    // is on what each row leads with.
    expect(rows).toHaveLength(3);
    expect(rows[0].startsWith("alpha")).toBe(true);
    expect(rows[1].startsWith("beta")).toBe(true);
    expect(rows[2].startsWith("gamma")).toBe(true);
  });
});

describe("searching the packages list", () => {
  it("searches summaries without matching description-only words", async () => {
    const rows = [
      { name: "unfiltered", query: "", count: 2, first: null },
      {
        name: "summary word",
        query: "shellcheck",
        count: 1,
        first: "preflight",
      },
      { name: "description-only word", query: "debug", count: 0, first: null },
    ];
    expect(rows).toHaveLength(3);
    for (const row of rows) {
      const found = await listed(row.query);
      expect(found, row.name).toHaveLength(row.count);
      if (row.first !== null) expect(found[0], row.name).toContain(row.first);
    }
  });
});

// The alias is not what a reader goes and fixes: the line names the place
// whose lock could not be read, and points at the page that explains it.
describe("naming what could not be read", () => {
  const projectRow = (root: string, name: string): MarketplaceRow => ({
    ...kit,
    scope: { scope: "project", root },
    name,
  });

  const lines = (): string[] => {
    const host = mount(<PackagesTab />);
    return [...host.querySelectorAll("p.text-warning")].map(
      (line) => line.textContent ?? "",
    );
  };

  // The catalog read succeeded — the packages are listed — but the lock
  // that would say what is installed could not be read, and the Problems
  // page is where that is explained. The cached row still says "available":
  // packages are read once and kept, so a scope readable when they landed
  // and broken since is exactly this disagreement, and the scope's answer
  // is the fresher one.
  it("names the project whose records left its rows unknown, and links to Problems", () => {
    const row = {
      ...projectRow("/home/dev/hyprtrade", "kendex"),
      recordsUnreadable: true,
    };
    useMarketplacesStore.setState({
      rows: [row],
      packages: { [marketKey(row.scope, row.name)]: [offered[0]] },
      readErrors: {},
    });
    const host = mount(<PackagesTab />);
    expect(host.textContent).toContain(unreadableRecordsLine("hyprtrade"));
    expect(host.textContent).toContain(SEE_PROBLEMS_LABEL);
    // The same fact travels down to each row, so the table under the line
    // cannot offer an install the line says nothing is known about.
    expect(
      [...host.querySelectorAll("button")].map((b) => b.textContent),
    ).not.toContain("Install");
  });

  // A project registered after the app's startup update read: that read has
  // not run again, so a `records` joined from its list of places would find
  // nothing and leave that project's unknown rows under no line at all.
  // The overview read that produced the rows carries the answer with them.
  it("names a place the update read has never heard of", () => {
    const row = {
      ...projectRow("/home/dev/just-added", "kendex"),
      recordsUnreadable: true,
    };
    useMarketplacesStore.setState({
      rows: [row],
      packages: {
        [marketKey(row.scope, row.name)]: [{ ...offered[0], state: "unknown" }],
      },
      readErrors: {},
    });
    expect(useUpdatesStore.getState().unreadable).toEqual([]);
    expect(lines()).toEqual([
      `${unreadableRecordsLine("just-added")} ${SEE_PROBLEMS_LABEL}`,
    ]);
  });

  // A marketplace read that produced no rows is judged by its kind, the
  // way the marketplace's own page judges it. A subscription nothing has
  // downloaded yet is the first-launch state, not a read failure: it gets
  // a neutral line naming the header's control, and the warning stays for
  // a read that went wrong — shaped or folded by the transport alike.
  it("tells a marketplace nothing has downloaded from one that could not be read", () => {
    const row = projectRow("/home/dev/hyprtrade", "kendex");
    const rows: {
      name: string;
      refusal: SourceReadRefused | string;
      warning: string[];
      shown: string[];
      absent: string[];
    }[] = [
      {
        name: "a shaped failure",
        refusal: { kind: "failed", message: "the clone is corrupt" },
        warning: [unreadableSourcesLine("hyprtrade")],
        shown: [],
        absent: [notDownloadedSourcesLine("hyprtrade")],
      },
      {
        name: "a transport failure",
        refusal: "the channel closed",
        warning: [unreadableSourcesLine("hyprtrade")],
        shown: [],
        absent: [notDownloadedSourcesLine("hyprtrade")],
      },
      {
        name: "a marketplace nothing has downloaded",
        refusal: { kind: "source-pending", source: "kendex" },
        warning: [],
        shown: [notDownloadedSourcesLine("hyprtrade"), CHECK_FOR_UPDATES_LABEL],
        absent: [unreadableSourcesLine("hyprtrade")],
      },
    ];
    expect(rows).toHaveLength(3);
    for (const { name, refusal, warning, shown, absent } of rows) {
      useMarketplacesStore.setState({
        rows: [row],
        packages: {},
        readErrors: {
          [readErrorKey(marketKey(row.scope, row.name), "packages")]: refusal,
        },
      });
      const host = mount(<PackagesTab />);
      expect(
        [...host.querySelectorAll("p.text-warning")].map(
          (line) => line.textContent,
        ),
        name,
      ).toEqual(warning);
      for (const text of shown) expect(host.textContent, name).toContain(text);
      for (const text of absent) {
        expect(host.textContent, name).not.toContain(text);
      }
    }
  });
});

// The Packages tab is the one table that shows a Marketplace column, so it
// is the only place the revision sub-line can be read. What the
// subscription declares it reads goes on screen as it is, except a commit
// id, which is shortened the way every git surface shortens one — a tag or
// a branch cut to seven characters would spell a different ref.
describe("the marketplace column's revision line", () => {
  const COMMIT = "0123456789abcdef0123456789abcdef01234567";

  const marketplaceCells = (rows: MarketplaceRow[]): string[] => {
    useMarketplacesStore.setState({
      rows,
      packages: Object.fromEntries(
        rows.map((row) => [
          marketKey(row.scope, row.name),
          offered.slice(0, 1),
        ]),
      ),
    });
    const host = mount(<PackagesTab />);
    return [...host.querySelectorAll("tbody tr")].map(
      (row) => row.querySelectorAll("td")[4]?.textContent ?? "",
    );
  };

  it("shows complete refs, shortened commits and no absent revision", () => {
    const rows = [
      {
        name: "cached commit",
        rev: null,
        commit: COMMIT,
        // The marketplace's resolved title, not the alias `kit` — see
        // `lib/marketplace-display.ts`.
        shown: ["Kit", "@ 0123456"],
        absent: [],
      },
      {
        name: "uppercase pinned commit",
        rev: COMMIT.toUpperCase(),
        commit: null,
        shown: ["@ 0123456"],
        absent: [COMMIT.toUpperCase()],
      },
      {
        name: "tracked branch",
        rev: "release/2026",
        commit: COMMIT,
        shown: ["@ release/2026"],
        absent: ["0123456"],
      },
      {
        name: "no revision",
        rev: null,
        commit: null,
        shown: [],
        absent: ["@"],
      },
    ];
    expect(rows).toHaveLength(4);
    for (const row of rows) {
      const [cell] = marketplaceCells([
        { ...kit, rev: row.rev, commit: row.commit },
      ]);
      for (const text of row.shown) expect(cell, row.name).toContain(text);
      for (const text of row.absent) expect(cell, row.name).not.toContain(text);
    }
  });
});

// Two subscriptions can be the same catalogue: the working checkout kendex
// is developed in, and the repository it was cloned from. Both declare one
// name in kendex.toml, so the column that names each row's marketplace has
// to say which of the two a row came from — the cards and the page header
// tell them apart by where they come from, and a list showing both at once
// cannot drop that.
describe("two marketplaces of one name in the marketplace column", () => {
  const local: MarketplaceRow = {
    ...kit,
    scope: { scope: "project", root: "/home/me/dev/kendex" },
    name: ".",
    repo: null,
    repoKey: null,
    repoIdentity: null,
    provenance: "/home/me/dev/kendex",
    path: ".",
    resolvedPath: "/home/me/dev/kendex",
    meta: { name: "kendex" },
  };
  const remote: MarketplaceRow = {
    ...kit,
    repo: "vanillagreencom/kendex",
    meta: { name: "kendex" },
  };

  it("tells the folder from the repository under one declared name", () => {
    useMarketplacesStore.setState({
      rows: [local, remote],
      packages: {
        [marketKey(local.scope, local.name)]: [offered[0]],
        [marketKey(remote.scope, remote.name)]: [offered[0]],
      },
      readErrors: {},
    });
    const host = mount(<PackagesTab />);
    // The Marketplace cell. The first cell is the tick a selection is made
    // in, so every column sits one along — the same offset `nameCell` and
    // `marketplaceCells` above account for.
    const cells = [...host.querySelectorAll("tbody tr")].map(
      (row) => row.querySelectorAll("td")[4],
    );

    // One name, as the catalogue declares it, on both rows.
    expect(cells.map((cell) => cell?.firstElementChild?.textContent)).toEqual([
      "kendex",
      "kendex",
    ]);
    // And one of them says which it is, in words and on the cell itself.
    const said = cells.map((cell) => cell?.textContent ?? "");
    expect(
      said.filter((text) => text.includes(LOCAL_FOLDER_LABEL)),
    ).toHaveLength(1);
    expect(cells.map((cell) => cell?.getAttribute("title"))).toEqual([
      `${LOCAL_FOLDER_LABEL} · /home/me/dev/kendex`,
      "vanillagreencom/kendex",
    ]);
  });
});
