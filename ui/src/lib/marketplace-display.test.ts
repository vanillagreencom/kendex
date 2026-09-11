import { describe, expect, it } from "vitest";
import type {
  CatalogSummary,
  DirectoryRow,
  MarketplaceRow,
  Scope,
} from "@/bindings";
import {
  LOCAL_FOLDER_LABEL,
  UNNAMED_MARKETPLACE,
} from "@/lib/copy-marketplaces";
import {
  catalogDisplay,
  catalogTitle,
  marketplaceDisplay,
  rowForCatalog,
  sourceLine,
} from "@/lib/marketplace-display";
import { catalogKey, subscription } from "@/stores/marketplaces-shared";

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
    // What core folds a folder to: the directory it resolves to.
    repoIdentity: resolvedPath,
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
// the same marketplace the card did, and it draws its breadcrumb before the
// overview read lands — so the address alone must never reach a title, which
// is the state a folder subscription keyed `.` would spell out.
describe("naming the catalog a page is showing", () => {
  const local = folder({ scope: project("/home/me/dev/kendex"), name: "." });
  const remote = row({ meta: { name: "kendex" } });
  const rows = [local, remote];
  const summary = (over: Partial<CatalogSummary> = {}): CatalogSummary => ({
    provenance: "acme/kit",
    repoKey: "acme/kit",
    repoIdentity: "github.com/acme/kit",
    commit: null,
    meta: null,
    mode: null as unknown as CatalogSummary["mode"],
    counts: {},
    warning: null,
    subscription: null,
    ...over,
  });

  it("resolves a subscription, an unread page and a bare repository", () => {
    const unread = subscription(project("/w/other"), ".");
    const cases = [
      {
        name: "the local checkout the card opened",
        catalog: subscription(project("/home/me/dev/kendex"), "."),
        summaries: {},
        title: "kendex",
      },
      {
        name: "the remote catalogue subscribed personally",
        catalog: subscription({ scope: "global" }, "kit"),
        summaries: {},
        title: "kendex",
      },
      {
        // Before the overview read lands, and after one fails, no row
        // declares the page. The alias is a relative path and names
        // nothing, so the address never stands as the title.
        name: "a folder page whose subscription rows have not arrived",
        catalog: unread,
        summaries: {},
        title: UNNAMED_MARKETPLACE,
      },
      {
        // The catalog's own account of itself arrives by another read, and
        // answers for the page until the rows do.
        name: "the same page once the catalog has been read",
        catalog: unread,
        summaries: {
          [catalogKey(unread)]: summary({ meta: { name: "kendex" } }),
        },
        title: "kendex",
      },
      {
        name: "a repository nobody subscribes to",
        catalog: { by: "repo" as const, repo: "acme/kit" },
        summaries: {},
        title: "kit",
      },
    ];
    expect(cases).toHaveLength(5);
    for (const each of cases) {
      const title = catalogTitle(rows, each.summaries, each.catalog);
      expect(title, each.name).toBe(each.title);
      expect([".", ".."], each.name).not.toContain(title);
    }
  });

  // A directory's label names a repository nobody subscribes to and has
  // read nothing from. It never outranks what the catalogue calls itself:
  // a page carried on as a subscription would otherwise wear the directory
  // label while its card and crumb wore the declared name.
  it("uses a directory's label below the catalogue's own name", () => {
    const repo = { by: "repo" as const, repo: "acme/kit" };
    const listed: DirectoryRow[] = [
      {
        repo: "acme/kit",
        repoKey: "acme/kit",
        repoIdentity: "github.com/acme/kit",
        name: "Kit by Acme",
        description: null,
        tags: [],
        featured: false,
        packageCount: 0,
        bundleCount: 0,
        subscribed: false,
        packages: [],
        bundles: [],
      },
    ];
    const read = { [catalogKey(repo)]: summary({ meta: { name: "kendex" } }) };

    expect(catalogDisplay(rows, {}, repo, listed).name).toBe("Kit by Acme");
    expect(catalogDisplay(rows, read, repo, listed).name).toBe("kendex");
    expect(catalogDisplay(rows, {}, repo, []).name).toBe("kit");
    // A subscription is never a directory row, so a Community page carried
    // on as one drops the label rather than keeping it over the crumb.
    // Asserted through an alias spelled like the listed repository and
    // declared by no place here: with the label suppressed the alias itself
    // answers, and a label reaching it would read "Kit by Acme" over a
    // subscription the directory knows nothing about.
    expect(
      catalogDisplay(
        rows,
        {},
        subscription({ scope: "global" }, "acme/kit"),
        listed,
      ).name,
    ).toBe("acme/kit");
  });

  // The card, the page and the crumb over it must name one marketplace.
  // A directory's label is a stranger's name for the repository: a card is
  // always a subscription row and never sees one, so a label that outlived
  // the conversion would leave the page and its crumb reading "Kit by Acme"
  // over a card reading what the subscription resolves to.
  it("drops a directory's label once the repository turns out to be subscribed", () => {
    const listed: DirectoryRow[] = [
      {
        repo: "acme/kit",
        repoKey: "acme/kit",
        repoIdentity: "github.com/acme/kit",
        name: "Kit by Acme",
        description: null,
        tags: [],
        featured: false,
        packageCount: 0,
        bundleCount: 0,
        subscribed: true,
        packages: [],
        bundles: [],
      },
    ];
    // A catalogue declaring no name of its own: what the label would
    // otherwise win against.
    const unnamed = row({ name: "kit", meta: null });
    const browsed = { by: "repo" as const, repo: "acme/kit" };
    const read = {
      [catalogKey(browsed)]: summary({
        meta: null,
        subscription: { scope: { scope: "global" as const }, source: "kit" },
      }),
    };

    // What the card says, from the row alone.
    const card = marketplaceDisplay(unnamed).name;
    // What the page and its crumb say, from the address it was opened by.
    const page = catalogDisplay([unnamed], read, browsed, listed).name;

    expect(page).toBe(card);
    expect(page).toBe("Kit");
    expect(page).not.toBe("Kit by Acme");

    // A repository nobody declares is still named by its listing: nothing
    // else on this machine has anything to say about it.
    expect(catalogDisplay([unnamed], {}, browsed, listed).name).toBe(
      "Kit by Acme",
    );
  });

  it("addresses the row a subscription names, and no other place's", () => {
    const cases = [
      {
        name: "the place that declares it",
        catalog: subscription(project("/home/me/dev/kendex"), "."),
        row: local,
      },
      {
        name: "another place declaring the same alias",
        catalog: subscription(project("/w/other"), "."),
        row: undefined,
      },
      {
        name: "a repository nobody subscribes to",
        catalog: { by: "repo" as const, repo: "acme/kit" },
        row: undefined,
      },
    ];
    expect(cases).toHaveLength(3);
    for (const each of cases)
      expect(rowForCatalog(rows, each.catalog), each.name).toBe(each.row);
  });
});
