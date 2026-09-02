import { describe, expect, it } from "vitest";
import type { MarketplaceRow, Scope } from "@/bindings";
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

// The identity keeps both cases, because they are opposite failures and no
// one mutation reddens both: folding what should split hands a live switch
// and Unsubscribe to another marketplace's subscription, and splitting what
// should fold is the duplication this page exists to remove.
describe("what makes two declarations one marketplace", () => {
  it("folds one repository however each place names it", () => {
    const groups = groupByMarketplace([
      elsewhere(),
      elsewhere({ scope: project("/w/alpha"), name: "acme-kit" }),
    ]);
    expect(groups).toHaveLength(1);
    expect(groups[0].places).toHaveLength(2);
  });

  it("keeps two repositories apart where only their alias agrees", () => {
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
});

// Every field on the card describes one subscription — the one it opens.
// Reporting whichever place had fetched first meant a card could name the
// project's subscription, show its revision and open its page while
// printing the personal one's count, which scopes pinned to different
// revisions can make a different number.
describe("the count a card carries", () => {
  it("reports no count where the opened place is unfetched and a sibling is not", () => {
    const [group] = groupByMarketplace([
      row({ enabled: false, counts: { skill: 9 } }),
      row({ scope: project("/w/alpha"), name: "alpha-kit", counts: null }),
    ]);

    expect(group.open.name).toBe("alpha-kit");
    expect(group.packages).toBeNull();
  });
});
