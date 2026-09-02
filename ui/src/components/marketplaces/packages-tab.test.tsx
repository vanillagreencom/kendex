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
