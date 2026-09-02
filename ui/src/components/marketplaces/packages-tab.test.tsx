// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it } from "vitest";
import type { AvailablePackage, MarketplaceRow } from "@/bindings";
import {
  SEE_PROBLEMS_LABEL,
  unreadableRecordsLine,
} from "@/lib/copy-marketplaces";
import { marketKey, useMarketplacesStore } from "@/stores/marketplaces";
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
  path: null,
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
  return [...host.querySelectorAll("tbody tr")].map(
    (row) => row.querySelector("td")?.textContent ?? "",
  );
};

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
  // decided on that. Sorting the raw identifier put "PreToolUse:*:alpha"
  // among the Ps while the reader saw "alpha" at the top.
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
  it("lists every package until something is typed", async () => {
    const rows = await listed("");
    expect(rows).toHaveLength(2);
  });

  it("matches a word from the summary", async () => {
    const rows = await listed("shellcheck");
    expect(rows).toHaveLength(1);
    expect(rows[0]).toContain("preflight");
  });

  it("does not match a word found only in the description", async () => {
    const rows = await listed("debug");
    expect(rows).toHaveLength(0);
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
  // nothing and leave the new project's unknown rows under no line at all.
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
      (row) => row.querySelectorAll("td")[3]?.textContent ?? "",
    );
  };

  it("names the marketplace and shortens the commit it is pinned to", () => {
    const [cell] = marketplaceCells([{ ...kit, rev: null, commit: COMMIT }]);
    expect(cell).toContain("kit");
    expect(cell).toContain("@ 0123456");
  });

  // A manifest may pin an uppercase id, and rev keeps the spelling it was
  // declared with. Core reads forty ASCII hex digits either way, so the
  // column must too — otherwise all forty land where the helper promises a
  // short revision.
  it("shortens an uppercase pin, the way core reads one", () => {
    const [cell] = marketplaceCells([
      { ...kit, rev: COMMIT.toUpperCase(), commit: null },
    ]);
    expect(cell).toContain("@ 0123456");
    expect(cell).not.toContain(COMMIT.toUpperCase());
  });

  // A tracked ref outranks the commit the cache happens to hold, and
  // release/2026 shortened would read as an unrelated tag called release.
  it("shows a tracked branch whole, over the commit behind it", () => {
    const [cell] = marketplaceCells([
      { ...kit, rev: "release/2026", commit: COMMIT },
    ]);
    expect(cell).toContain("@ release/2026");
    expect(cell).not.toContain("0123456");
  });

  it("carries no revision line for a subscription that declares none", () => {
    const [cell] = marketplaceCells([{ ...kit, rev: null, commit: null }]);
    expect(cell).not.toContain("@");
  });
});
