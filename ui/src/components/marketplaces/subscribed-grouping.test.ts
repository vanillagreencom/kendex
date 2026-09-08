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

// A non-GitHub remote. `repoKey` is source_ref::owner_repo, which answers
// only for github.com, so keying on it would leave every other host falling
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
  it("groups repositories by identity rather than their aliases", () => {
    const rows = [
      {
        name: "one repository under different aliases",
        declarations: [
          elsewhere(),
          elsewhere({ scope: project("/w/alpha"), name: "acme-kit" }),
        ],
        groups: 1,
        places: 2,
      },
      {
        name: "different repositories under the same alias",
        declarations: [
          elsewhere(),
          elsewhere({
            scope: project("/w/alpha"),
            repo: "https://git.internal/tools/kit",
            repoIdentity: "https://git.internal/tools/kit",
          }),
        ],
        groups: 2,
        places: null,
      },
    ];
    expect(rows).toHaveLength(2);
    for (const row of rows) {
      const groups = groupByMarketplace(row.declarations);
      expect(groups, row.name).toHaveLength(row.groups);
      if (row.places !== null)
        expect(groups[0].places, row.name).toHaveLength(row.places);
    }
  });
});

// A folder's identity is the directory core resolved it to, never the
// spelling. Which spellings are absolute is the running platform's answer:
// on Windows `/srv/catalog` is root-relative and joins onto each declaring
// scope's own drive, so a personal manifest on `C:` and a project on `D:`
// name two directories under one spelling. Read off the spelling, the two
// fold into one card whose switch and Unsubscribe aim at the other's
// subscription; read off the resolved path, one directory declared twice
// still folds.
describe("what makes two folder declarations one marketplace", () => {
  const folder = (
    scope: Scope,
    path: string,
    resolvedPath: string,
  ): MarketplaceRow =>
    row({
      scope,
      name: "catalog",
      repo: null,
      repoKey: null,
      repoIdentity: null,
      provenance: resolvedPath,
      path,
      resolvedPath,
    });

  it("groups folders by the directory core resolved", () => {
    const rows = [
      {
        name: "one spelling resolves to different directories",
        declarations: [
          folder({ scope: "global" }, "/srv/catalog", "C:/srv/catalog"),
          folder(project("D:/work/beta"), "/srv/catalog", "D:/srv/catalog"),
        ],
        keys: ["C:/srv/catalog", "D:/srv/catalog"],
        places: null,
      },
      {
        name: "different spellings resolve to one directory",
        declarations: [
          folder(
            { scope: "global" },
            "/work/beta/catalog",
            "/work/beta/catalog",
          ),
          folder(project("/work/beta"), "catalog", "/work/beta/catalog"),
        ],
        keys: ["/work/beta/catalog"],
        places: 2,
      },
    ];
    expect(rows).toHaveLength(2);
    for (const row of rows) {
      const groups = groupByMarketplace(row.declarations);
      expect(
        groups.map((group) => group.key),
        row.name,
      ).toEqual(row.keys);
      if (row.places !== null)
        expect(groups[0].places, row.name).toHaveLength(row.places);
    }
  });
});

// Every field on the card describes one subscription — the one it opens.
// Reporting whichever place fetched first would let a card name the
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
