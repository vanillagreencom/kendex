import { describe, expect, it } from "vitest";
import type { MarketplaceRow, Origin, ProvenanceRow, Scope } from "@/bindings";
import { installElsewhere } from "@/lib/install-elsewhere";

const VG: Scope = { scope: "project", root: "/work/vg" };

const from = (origin: Origin): ProvenanceRow[] => [
  {
    scope: VG,
    kind: "skill",
    name: "gh",
    harness: "claude",
    at: "/x/claude",
    origin,
    package: { kind: "skill", name: "gh" },
  },
];

/** A subscription as a scope declares it: the alias the person chose, and
 *  the repository it resolved to. Both, because the alias is a name a
 *  scope picked and two scopes may pick the same one for different
 *  repositories. */
const declared = (
  scope: Scope,
  name: string,
  provenance = "o/r",
): MarketplaceRow => ({ scope, name, provenance }) as MarketplaceRow;

const MARKET: Origin = { origin: "marketplace", source: "cat", repo: "o/r" };
const MINE: Origin = { origin: "own", forkedFrom: null, source: "local" };

/** What the Projects tab's Install link is offered over. The engine
 *  redirects an install into a project the reader picks only from a
 *  globally declared subscription, so those are the only rows this may
 *  build an ask from: anything else opens a dialog whose install is
 *  refused. One row per way of arriving at each answer.
 */
describe("installing a package into a project that lacks it", () => {
  const rows: [string, ProvenanceRow[], MarketplaceRow[], boolean][] = [
    [
      "a marketplace this machine subscribes to for itself",
      from(MARKET),
      [declared({ scope: "global" }, "cat")],
      true,
    ],
    [
      "the same marketplace declared only inside a project",
      from(MARKET),
      [declared(VG, "cat")],
      false,
    ],
    [
      "a marketplace nothing declares",
      from(MARKET),
      [declared({ scope: "global" }, "other")],
      false,
    ],
    [
      "a global subscription under the same alias for another repository",
      from(MARKET),
      [declared({ scope: "global" }, "cat", "other/repo")],
      false,
    ],
    [
      "a global subscription whose catalog could not be read",
      from(MARKET),
      [{ scope: { scope: "global" }, name: "cat" } as MarketplaceRow],
      false,
    ],
    [
      "the reader's own package, which came from no marketplace",
      from(MINE),
      [declared({ scope: "global" }, "cat")],
      false,
    ],
    [
      "no copies recorded at all",
      [],
      [declared({ scope: "global" }, "cat")],
      false,
    ],
  ];
  it.each(rows)("%s", (_what, provenance, subscriptions, offered) => {
    const ask = installElsewhere(
      "skill",
      "gh",
      "gh",
      provenance,
      subscriptions,
    );
    expect(ask !== null).toBe(offered);
  });

  it("installs the package from the marketplace its copies came from", () => {
    const ask = installElsewhere("skill", "gh", "gh", from(MARKET), [
      declared({ scope: "global" }, "cat"),
    ]);
    expect(ask?.groups).toEqual([
      {
        source: "cat",
        browsing: { scope: "global" },
        items: [{ kind: "skill", name: "gh" }],
        bundle: null,
      },
    ]);
    expect(ask?.count).toBe(1);
  });
});
