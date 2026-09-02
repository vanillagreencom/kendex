import { describe, expect, it } from "vitest";
import type { MarketplaceRow, Scope } from "@/bindings";
import { groupByMarketplace, placeNames } from "./subscribed-grouping";

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
  ...over,
});

// A non-GitHub remote. `repoKey` is source_ref::owner_repo, which answers
// only for github.com, so keying on it left every other host falling
// through to the per-place alias — and auto_alias uniquifies a name inside
// one scope's manifest only.
const elsewhere = (over: Partial<MarketplaceRow> = {}): MarketplaceRow =>
  row({
    repo: "https://gitlab.com/acme/kit",
    repoKey: null,
    repoIdentity: "https://gitlab.com/acme/kit",
    ...over,
  });

describe("grouping subscriptions into marketplaces", () => {
  // The alias is a per-place spelling, so it cannot be the identity: three
  // places holding the same repository are one catalog however each names
  // it, and the old per-place list drew them as three unrelated rows.
  it("folds the same repository in three places into one card", () => {
    const groups = groupByMarketplace([
      row(),
      row({ scope: project("/w/alpha"), name: "acme-kit" }),
      row({ scope: project("/w/beta"), name: "vendor-kit" }),
    ]);
    expect(groups).toHaveLength(1);
    expect(groups[0].places).toHaveLength(3);
  });

  // The bug this helper exists to stop: two unrelated marketplaces landing
  // in one card, whose Projects section then aims its switch and its
  // Unsubscribe at the other one's subscription.
  it("keeps two non-GitHub repositories sharing an alias apart", () => {
    const groups = groupByMarketplace([
      elsewhere(),
      elsewhere({
        scope: project("/w/alpha"),
        repo: "https://git.internal/tools/kit",
        repoIdentity: "https://git.internal/tools/kit",
      }),
    ]);
    expect(groups).toHaveLength(2);
  });

  it("folds one non-GitHub repository held under two aliases", () => {
    const groups = groupByMarketplace([
      elsewhere(),
      elsewhere({ scope: project("/w/alpha"), name: "acme-kit" }),
    ]);
    expect(groups).toHaveLength(1);
    expect(groups[0].places).toHaveLength(2);
  });

  it("keeps two different repositories apart", () => {
    const groups = groupByMarketplace([
      row(),
      row({
        name: "tools",
        repo: "Acme/Tools",
        repoKey: "acme/tools",
        repoIdentity: "github.com/acme/tools",
      }),
    ]);
    expect(groups).toHaveLength(2);
  });

  // A local folder has no canonical repository key; the path is what two
  // places subscribing to it have in common.
  it("folds local folders by their path", () => {
    const local = {
      repo: null,
      repoKey: null,
      repoIdentity: null,
      path: "/srv/catalog",
    };
    const groups = groupByMarketplace([
      row(local),
      row({ ...local, scope: project("/w/alpha"), name: "catalog" }),
    ]);
    expect(groups).toHaveLength(1);
    expect(groups[0].where).toBe("/srv/catalog");
  });

  it("names its places personal first", () => {
    const groups = groupByMarketplace([
      row({ scope: project("/w/beta") }),
      row(),
    ]);
    expect(placeNames(groups[0])).toEqual(["Personal", "beta"]);
  });

  // The card opens one subscription, and opening a switched-off one lands
  // on a page whose packages nothing will install.
  it("opens a place that is switched on over one that is not", () => {
    const groups = groupByMarketplace([
      row({ enabled: false }),
      row({ scope: project("/w/alpha"), name: "alpha-kit" }),
    ]);
    expect(groups[0].open.name).toBe("alpha-kit");
  });

  it("opens personal when every place is switched on", () => {
    const groups = groupByMarketplace([
      row({ scope: project("/w/alpha"), name: "alpha-kit" }),
      row(),
    ]);
    expect(groups[0].open.scope.scope).toBe("global");
  });

  // A count is only known where a catalog has actually been fetched; one
  // place having read it answers for the marketplace.
  it("takes the package count from the first place that has one", () => {
    const groups = groupByMarketplace([
      row(),
      row({ scope: project("/w/alpha"), counts: { skill: 3, agent: 1 } }),
    ]);
    expect(groups[0].packages).toBe(4);
  });

  it("has no count while no place has fetched the catalog", () => {
    expect(groupByMarketplace([row()])[0].packages).toBeNull();
  });
});
