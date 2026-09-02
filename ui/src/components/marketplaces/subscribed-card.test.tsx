// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { MarketplaceRow, Scope } from "@/bindings";
import { morePlacesLabel } from "@/lib/copy";
import { placeCountLabel } from "@/lib/copy-marketplaces";
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
  path: null,
  rev: null,
  commit: null,
  enabled: true,
  counts: null,
  meta: null,
  mode: null,
  recordsUnreadable: false,
  ...over,
});

/** The card as the tab draws it: from a real grouping, never a hand-built
 * group, so the fixture cannot disagree with what the tab passes. */
const draw = (rows: MarketplaceRow[]) => {
  const [group] = groupByMarketplace(rows);
  const host = mount(<SubscribedCard group={group} />);
  return { host, text: host.textContent ?? "" };
};

const goToMarketplace = vi.fn();

beforeEach(() => {
  goToMarketplace.mockReset();
  useNavStore.setState({ goToMarketplace });
});

// The switch left this list for the marketplace page, so the badge is now
// the only thing on the Subscribed tab that says a subscription is not
// offering its packages anywhere.
describe("a card whose places are not all offering packages", () => {
  it("counts the places that are switched off", () => {
    const { text } = draw([
      row(),
      row({ scope: project("/w/beta"), enabled: false }),
    ]);
    expect(text).toContain("Off in 1");
    expect(text).not.toContain("Switched off");
  });

  it("says so plainly when no place is offering them", () => {
    const { text } = draw([
      row({ enabled: false }),
      row({ scope: project("/w/beta"), enabled: false }),
    ]);
    expect(text).toContain("Switched off");
    expect(text).not.toContain("Off in");
  });

  it("says neither when every place is offering them", () => {
    const { text } = draw([row(), row({ scope: project("/w/beta") })]);
    expect(text).not.toContain("Switched off");
    expect(text).not.toContain("Off in");
  });
});

describe("the places line", () => {
  it("names each place while they fit", () => {
    const { text } = draw([
      row(),
      row({ scope: project("/w/alpha") }),
      row({ scope: project("/w/beta") }),
    ]);
    expect(text).toContain(placeCountLabel(3));
    expect(text).toContain("Personal, alpha, beta");
    expect(text).not.toContain(morePlacesLabel(1));
  });

  // Three names is the cap; a fourth place is counted rather than listed,
  // so the line cannot grow past the card.
  it("counts the ones past the third instead of listing them", () => {
    const { text } = draw([
      row(),
      row({ scope: project("/w/alpha") }),
      row({ scope: project("/w/beta") }),
      row({ scope: project("/w/gamma") }),
    ]);
    expect(text).toContain(placeCountLabel(4));
    expect(text).toContain("Personal, alpha, beta");
    expect(text).toContain(morePlacesLabel(1));
    expect(text).not.toContain("gamma");
  });
});

describe("what the card says about the catalog", () => {
  it("says the catalog has not been fetched rather than showing a zero", () => {
    const { text } = draw([row()]);
    expect(text).toContain("Not fetched yet");
    expect(text).not.toContain("0 packages");
  });

  it("counts the packages once a place has read the catalog", () => {
    const { text } = draw([row({ counts: { skill: 3, agent: 1 } })]);
    expect(text).toContain("4 packages");
    expect(text).not.toContain("Not fetched yet");
  });

  it("shows a pinned commit shortened and a tracked branch whole", () => {
    const commit = "0123456789abcdef0123456789abcdef01234567";
    expect(draw([row({ commit })]).text).toContain("@ 0123456");
    expect(draw([row({ rev: "release/2026" })]).text).toContain(
      "@ release/2026",
    );
  });
});

// The card opens one subscription out of several. Opening a switched-off
// one lands on a page whose packages nothing will install, so the choice
// is the group's `open`, not whichever place the list happened to hold
// first.
describe("opening the marketplace", () => {
  it("opens a place that is offering packages, not the first-listed one", async () => {
    const { host } = draw([
      row({ enabled: false }),
      row({ scope: project("/w/alpha"), name: "alpha-kit" }),
    ]);
    const card = host.querySelector("button");
    if (!card) throw new Error("no card button rendered");

    await userEvent.click(card);

    expect(goToMarketplace).toHaveBeenCalledWith(
      subscription(project("/w/alpha"), "alpha-kit"),
    );
  });
});
