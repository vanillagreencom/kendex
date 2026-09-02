// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it } from "vitest";
import type { AvailablePackage, MarketplaceRow } from "@/bindings";
import {
  SEE_PROBLEMS_LABEL,
  unreadableRecordsLine,
  unreadableSourcesLine,
} from "@/lib/copy-marketplaces";
import {
  marketKey,
  readErrorKey,
  useMarketplacesStore,
} from "@/stores/marketplaces";
import { usePreinstallSafety } from "@/stores/preinstall-safety";
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

// The alias is not what a reader goes and fixes. One alias subscribed in
// three projects printed three identical lines naming no project at all,
// and pointed at a tab that showed nothing wrong.
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

  it("names each project once, however many of its marketplaces failed", () => {
    const one = projectRow("/home/dev/hyprtrade", "kendex");
    const two = projectRow("/home/dev/hyprtrade", "kendex-2");
    useMarketplacesStore.setState({
      rows: [one, two],
      packages: {},
      readErrors: {
        [readErrorKey(marketKey(one.scope, one.name), "packages")]: "no",
        [readErrorKey(marketKey(two.scope, two.name), "packages")]: "no",
      },
    });
    expect(lines()).toEqual([unreadableSourcesLine("hyprtrade")]);
  });

  it("names one project per scope when the same alias is subscribed twice", () => {
    const here = projectRow("/home/dev/hyprtrade", "kendex");
    const there = projectRow("/home/dev/kendex-web", "kendex");
    useMarketplacesStore.setState({
      rows: [here, there],
      packages: {},
      readErrors: {
        [readErrorKey(marketKey(here.scope, here.name), "packages")]: "no",
        [readErrorKey(marketKey(there.scope, there.name), "packages")]: "no",
      },
    });
    expect(lines()).toEqual([
      unreadableSourcesLine("hyprtrade"),
      unreadableSourcesLine("kendex-web"),
    ]);
  });

  // The catalog read succeeded — the packages are listed — but the rows
  // carry no installed state, and the Problems page is where the record
  // that would answer is explained.
  it("names the project whose records left its rows unknown, and links to Problems", () => {
    const row = projectRow("/home/dev/hyprtrade", "kendex");
    useMarketplacesStore.setState({
      rows: [row],
      packages: {
        [marketKey(row.scope, row.name)]: [{ ...offered[0], state: "unknown" }],
      },
      readErrors: {},
    });
    const host = mount(<PackagesTab />);
    expect(host.textContent).toContain(unreadableRecordsLine("hyprtrade"));
    expect(host.textContent).toContain(SEE_PROBLEMS_LABEL);
  });

  it("says nothing when every read landed", () => {
    expect(lines()).toEqual([]);
  });
});
