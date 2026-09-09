import { describe, expect, it } from "vitest";
import type { MarketplaceRow, Scope } from "@/bindings";
import {
  LOCAL_FOLDER_LABEL,
  UNNAMED_MARKETPLACE,
} from "@/lib/copy-marketplaces";
import {
  catalogTitle,
  marketplaceDisplay,
  rowForCatalog,
  sourceLine,
} from "@/lib/marketplace-display";
import { subscription } from "@/stores/marketplaces-shared";

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

/** A folder declared in one place's manifest, as core resolves it. */
const folder = (
  over: Partial<MarketplaceRow> = {},
  path = ".",
  resolvedPath = "/home/me/dev/kendex",
): MarketplaceRow =>
  row({
    repo: null,
    repoKey: null,
    repoIdentity: null,
    provenance: resolvedPath,
    path,
    resolvedPath,
    ...over,
  });

// The alias is one place's manifest key, not a name: `[sources."."]` with
// `path = "."` is the working checkout the app itself is developed in, and
// `.` names nothing on a card. What the catalog calls itself leads; the
// folder or repository it resolves to answers where it says nothing.
describe("what a marketplace is called", () => {
  it("titles a subscription from its catalog, its folder or its repository", () => {
    const rows = [
      {
        name: "the catalogue's declared name",
        row: folder({ meta: { name: "kendex" } }),
        title: "kendex",
      },
      {
        name: "a relative folder with no metadata read",
        row: folder(),
        title: "kendex",
      },
      {
        // Nothing left to take a name from: no metadata, no folder segment
        // and an alias that spells a relative path.
        name: "a folder resolved to the filesystem root",
        row: folder({ name: "." }, ".", "/"),
        title: "/",
      },
      {
        name: "a repository with no metadata read",
        row: row(),
        title: "Kit",
      },
      {
        name: "a parent-folder alias",
        row: folder({ name: ".." }, "..", "/home/me/dev"),
        title: "dev",
      },
      {
        name: "a declaration naming neither folder nor repository",
        row: row({
          name: ".",
          repo: null,
          repoKey: null,
          repoIdentity: null,
          provenance: null,
        }),
        title: UNNAMED_MARKETPLACE,
      },
    ];
    expect(rows).toHaveLength(6);
    for (const each of rows) {
      const title = marketplaceDisplay(each.row).name;
      expect(title, each.name).toBe(each.title);
      expect([".", ".."], each.name).not.toContain(title);
    }
  });

  // Two sources can call themselves the same thing — a working checkout and
  // the remote catalogue it was cloned from do exactly that. The title is
  // the same on purpose; the line under it is what tells them apart.
  it("tells a local checkout from the remote catalogue of the same name", () => {
    const meta = { name: "kendex" };
    const local = marketplaceDisplay(folder({ meta }));
    const remote = marketplaceDisplay(
      row({ meta, repo: "vanillagreencom/kendex" }),
    );

    expect(local.name).toBe(remote.name);
    expect(sourceLine(local)).toBe(
      `${LOCAL_FOLDER_LABEL} · /home/me/dev/kendex`,
    );
    expect(sourceLine(remote)).toBe("vanillagreencom/kendex");
  });

  // The alias is what `unsubscribe` and the manifest address the source by,
  // so the details flow keeps it whatever the title reads.
  it("keeps the alias the manifest declares", () => {
    expect(marketplaceDisplay(folder({ meta: { name: "kendex" } })).alias).toBe(
      "kit",
    );
  });
});

// One catalog addresses one subscription. A page opened from a card names
// the same marketplace the card did, and an alias declared in two places
// must not answer for the other place's subscription.
describe("naming the catalog a page is showing", () => {
  const local = folder({ scope: project("/home/me/dev/kendex"), name: "." });
  const remote = row({ meta: { name: "kendex" } });
  const rows = [local, remote];

  it("resolves a subscription, a foreign alias and a bare repository", () => {
    const cases = [
      {
        name: "the local checkout the card opened",
        catalog: subscription(project("/home/me/dev/kendex"), "."),
        title: "kendex",
        row: local,
      },
      {
        name: "the remote catalogue subscribed personally",
        catalog: subscription({ scope: "global" }, "kit"),
        title: "kendex",
        row: remote,
      },
      {
        name: "an alias no place in this list declares",
        catalog: subscription(project("/w/other"), "."),
        title: ".",
        row: undefined,
      },
      {
        name: "a repository nobody subscribes to",
        catalog: { by: "repo" as const, repo: "acme/kit" },
        title: "acme/kit",
        row: undefined,
      },
    ];
    expect(cases).toHaveLength(4);
    for (const each of cases) {
      expect(catalogTitle(rows, each.catalog), each.name).toBe(each.title);
      expect(rowForCatalog(rows, each.catalog), each.name).toBe(each.row);
    }
  });
});
