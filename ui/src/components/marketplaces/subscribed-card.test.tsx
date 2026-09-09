// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { MarketplaceRow, Scope } from "@/bindings";
import { LOCAL_FOLDER_LABEL } from "@/lib/copy-marketplaces";
import { subscription } from "@/stores/marketplaces-shared";
import { useNavStore } from "@/stores/nav";
import { mount } from "@/test/dom";
import { SubscribedCard } from "./subscribed-card";
import { groupByMarketplace } from "./subscribed-grouping";

const project = (root: string): Scope => ({ scope: "project", root });

const row = (over: Partial<MarketplaceRow> = {}): MarketplaceRow => ({
  scope: { scope: "global" },
  name: "kit",
  repo: "Acme/Kit",
  repoKey: "acme/kit",
  repoIdentity: "github.com/acme/kit",
  provenance: "Acme/Kit",
  path: null,
  resolvedPath: null,
  rev: null,
  commit: null,
  enabled: true,
  counts: null,
  meta: null,
  mode: null,
  recordsUnreadable: false,
  ...over,
});

const goToMarketplace = vi.fn();

beforeEach(() => {
  goToMarketplace.mockReset();
  useNavStore.setState({ goToMarketplace });
});

// The card opens the marketplace, and which of its places it opens as is
// the choice: a switched-off one lands the reader on a page whose packages
// nothing will install. Drawn from a real grouping, so the fixture cannot
// disagree with what the tab passes.
describe("opening a marketplace from its card", () => {
  it("opens a place that is offering packages, not the first-listed one", async () => {
    const [group] = groupByMarketplace([
      row({ enabled: false }),
      row({ scope: project("/w/alpha"), name: "alpha-kit" }),
    ]);
    const host = mount(<SubscribedCard group={group} />);
    const card = host.querySelector("button");
    if (!card) throw new Error("no card button rendered");

    await userEvent.click(card);

    expect(goToMarketplace).toHaveBeenCalledWith(
      subscription(project("/w/alpha"), "alpha-kit"),
    );
  });
});

// The card the reader meets first. Titled by the alias it read `.` for the
// working checkout kendex is developed in, over the official catalogue's
// description; two cards for one catalogue and its clone read as the same
// marketplace listed twice unless the line under the title says which is
// which.
describe("what a card calls a marketplace", () => {
  it("titles both by the catalogue and separates the folder from the remote", () => {
    const meta = { name: "kendex" };
    const groups = groupByMarketplace([
      row({ meta, repo: "vanillagreencom/kendex" }),
      row({
        scope: project("/home/me/dev/kendex"),
        name: ".",
        repo: null,
        repoKey: null,
        repoIdentity: null,
        provenance: "/home/me/dev/kendex",
        path: ".",
        resolvedPath: "/home/me/dev/kendex",
        meta,
      }),
    ]);
    expect(groups).toHaveLength(2);

    const drawn = groups.map((group) => {
      const host = mount(<SubscribedCard group={group} />);
      return {
        title:
          host.querySelector("span.truncate.font-medium")?.textContent ?? "",
        said: host.textContent ?? "",
      };
    });

    expect(drawn.map((card) => card.title)).toEqual(["kendex", "kendex"]);
    expect(
      drawn
        .map((card) => card.said.includes("vanillagreencom/kendex"))
        .filter(Boolean),
    ).toHaveLength(1);
    expect(
      drawn
        .map((card) =>
          card.said.includes(`${LOCAL_FOLDER_LABEL} · /home/me/dev/kendex`),
        )
        .filter(Boolean),
    ).toHaveLength(1);
  });
});
