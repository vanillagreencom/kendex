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

  // The catalog read succeeded — the packages are listed — but the lock
  // that would say what is installed could not be read, and the Problems
  // page is where that is explained.
  it("names the project whose records left its rows unknown, and links to Problems", () => {
    const row = {
      ...projectRow("/home/dev/hyprtrade", "kendex"),
      recordsUnreadable: true,
    };
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

  // Both failures at once is where a `records` inferred from row states
  // breaks: the catalog read failed, so there are no cached rows to carry
  // an "unknown" state, and the project would get the sources line with no
  // way to the reason. The scope-level fact does not depend on rows.
  it("names a project with both failures once, under sources, still linking to Problems", () => {
    const row = {
      ...projectRow("/home/dev/hyprtrade", "kendex"),
      recordsUnreadable: true,
    };
    useMarketplacesStore.setState({
      rows: [row],
      packages: {},
      readErrors: {
        [readErrorKey(marketKey(row.scope, row.name), "packages")]: "no",
      },
    });
    const host = mount(<PackagesTab />);
    expect(
      [...host.querySelectorAll("p.text-warning")].map(
        (line) => line.textContent ?? "",
      ),
    ).toEqual([`${unreadableSourcesLine("hyprtrade")} ${SEE_PROBLEMS_LABEL}`]);
  });

  // A subscription turned off contributes no rows to the table, so a read
  // error left over from when it was on has nothing under it to explain.
  it("says nothing for a disabled subscription that once failed to read", () => {
    const row = {
      ...projectRow("/home/dev/hyprtrade", "kendex"),
      enabled: false,
    };
    useMarketplacesStore.setState({
      rows: [row],
      packages: {},
      readErrors: {
        [readErrorKey(marketKey(row.scope, row.name), "packages")]: "no",
      },
    });
    expect(lines()).toEqual([]);
  });

  // scopeName is a basename, so two projects in different parents would
  // print the same line twice with nothing to say which had the problem.
  it("tells apart two projects whose folders share a name", () => {
    const here = projectRow("/home/dev/kendex", "kit");
    const there = projectRow("/home/work/kendex", "kit");
    useMarketplacesStore.setState({
      rows: [here, there],
      packages: {},
      readErrors: {
        [readErrorKey(marketKey(here.scope, here.name), "packages")]: "no",
        [readErrorKey(marketKey(there.scope, there.name), "packages")]: "no",
      },
    });
    expect(lines()).toEqual([
      unreadableSourcesLine("/home/dev/kendex"),
      unreadableSourcesLine("/home/work/kendex"),
    ]);
  });

  // The personal scope holds a lock of its own, so it lands in the same
  // list — named as what it is rather than called a project.
  it("names the personal scope by its own name", () => {
    useMarketplacesStore.setState({
      rows: [{ ...kit, recordsUnreadable: true }],
      packages: { [marketKey(kit.scope, kit.name)]: offered },
      readErrors: {},
    });
    expect(lines()).toEqual([
      `${unreadableRecordsLine("Personal")} ${SEE_PROBLEMS_LABEL}`,
    ]);
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

  it("says nothing when every read landed", () => {
    expect(lines()).toEqual([]);
  });
});
