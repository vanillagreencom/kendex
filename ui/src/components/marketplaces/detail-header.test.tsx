// @vitest-environment jsdom
import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Catalog, DirectoryRow, MarketplaceRow } from "@/bindings";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  LOCAL_FOLDER_LABEL,
  MARKETPLACES_UNCONFIRMED_TITLE,
} from "@/lib/copy-marketplaces";
import { displayFor } from "@/lib/marketplace-display";
import { useCommunityStore } from "@/stores/community";
import { mount } from "@/test/dom";
import { DetailHeader } from "./detail-header";

// What a Community row opens as: the page is asked for the listing's own
// spelling, and the listing is found by it.
const LISTED_REPO = "https://gitlab.example/acme/kit.git";
const repoCatalog: Catalog = { by: "repo", repo: LISTED_REPO };

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so the store is wrapped to let a test stage what the last read
// left behind.
const stub = vi.hoisted(() => ({
  read: { status: "landed", error: null } as {
    status: "pending" | "landed" | "failed";
    error: string | null;
  },
}));

vi.mock("@/stores/marketplaces", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/marketplaces")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useMarketplacesStore.getState(),
      ...stub,
      load: async () => {},
    };
    return selector ? selector(state) : state;
  };
  return {
    ...mod,
    useMarketplacesStore: Object.assign(hook, mod.useMarketplacesStore),
  };
});

const catalog: Catalog = {
  by: "subscription",
  scope: { scope: "global" },
  source: "kit",
};

const BASE: MarketplaceRow = {
  scope: { scope: "global" },
  name: "kit",
  repo: "Acme/Kit",
  repoKey: "acme/kit",
  repoIdentity: "github.com/acme/kit",
  provenance: null,
  path: null,
  resolvedPath: null,
  rev: null,
  commit: null,
  enabled: true,
  counts: null,
  meta: null,
  mode: null,
  recordsUnreadable: false,
};

// A fresh row per render. A test that mutates a shared one and undoes it at
// the end of its body leaves the mutation behind the moment an assertion
// fails, and the next test goes red for somebody else's reason.
/** The page resolves this once and hands it down — `useCatalog` owns it,
 *  because it alone holds the summary that discovered a subscription. */
const shown = (row: MarketplaceRow, listedName?: string) =>
  displayFor({ catalog, row, summary: null, listedName });

const render = (row: Partial<MarketplaceRow> = {}) => {
  const full = { ...BASE, ...row };
  return renderToStaticMarkup(
    <DetailHeader
      requested={catalog}
      catalog={catalog}
      row={full}
      summary={null}
      display={shown(full)}
    />,
  );
};

beforeEach(() => {
  stub.read = { status: "landed", error: null };
});

// The detail page selects its row from the store's retained rows, so a
// failed overview re-read leaves it drawing a subscription nobody could
// confirm — said on the page, with the retry beside it.
describe("DetailHeader subscription read state", () => {
  it("labels retained subscriptions only when their read failed", () => {
    const rows = [
      { name: "failed", read: { status: "failed" as const, error: "offline" } },
      { name: "current", read: { status: "landed" as const, error: null } },
    ];
    expect(rows).toHaveLength(2);
    for (const row of rows) {
      stub.read = row.read;
      const html = render();
      if (row.read.status === "failed") {
        expect(html, row.name).toContain(MARKETPLACES_UNCONFIRMED_TITLE);
        expect(html, row.name).toContain("offline");
        expect(html, row.name).toContain(TRY_AGAIN_LABEL);
      } else
        expect(html, row.name).not.toContain(MARKETPLACES_UNCONFIRMED_TITLE);
    }
  });
});

// The repository and the homepage belong in the header, and both open the
// person's own browser rather than a page inside the app.
describe("the header's links out", () => {
  it("makes the repository a link to its page", () => {
    const html = render();
    expect(html).toMatch(/<button[^>]*>Acme\/Kit<\/button>/);
    expect(html).toContain("text-info");
  });

  // The header draws before the catalog is read, so on a Community-to-repo
  // open the directory listing is what supplies the key. `DirectoryRow`
  // carries the canonical fold beside the raw entry, and only the fold may
  // build a github.com URL: the raw one is whatever the index happened to
  // hold — a full URL, a `.git` suffix, another host.
  it("builds the link from the folded key, never the listing's raw entry", () => {
    const listed: DirectoryRow = {
      repo: LISTED_REPO,
      repoKey: null,
      repoIdentity: "https://gitlab.example/acme/kit",
      name: "Kit",
      description: null,
      tags: [],
      featured: false,
      packageCount: 0,
      bundleCount: 0,
      subscribed: false,
      packages: [],
      bundles: [],
    };
    useCommunityStore.setState({
      directory: {
        rows: [listed],
        fetchedAt: "2026-01-01T00:00:00Z",
        stale: false,
      },
    });
    // A mounted tree: a static render serves the store's initial snapshot,
    // never one a test set afterwards.
    const host = mount(
      <DetailHeader
        requested={repoCatalog}
        catalog={repoCatalog}
        row={undefined}
        summary={null}
        display={displayFor({
          catalog: repoCatalog,
          listedName: listed.name,
        })}
      />,
    );
    // The URL itself lives in the click handler, never in the markup, so
    // what says the fold refused is that the provenance is text and not a
    // link: a link here would open github.com/https://gitlab.example/…
    const html = host.innerHTML;
    expect(html).toMatch(/<span[^>]*>https:\/\/gitlab\.example[^<]*<\/span>/);
    expect(html).not.toMatch(
      /<button[^>]*>https:\/\/gitlab\.example[^<]*<\/button>/,
    );
  });
});

// The alias is one place's manifest key. A page titled by it puts `.` over
// the official catalogue's description for the working checkout kendex
// itself is developed in, and the card the reader clicked said something
// else. One resolution answers the card, this header and the breadcrumb.
describe("what the header calls the marketplace", () => {
  const drawn = (row: Partial<MarketplaceRow>) => {
    const full = { ...BASE, ...row };
    const host = mount(
      <DetailHeader
        requested={catalog}
        catalog={catalog}
        row={full}
        summary={null}
        display={shown(full)}
      />,
    );
    return {
      title: host.querySelector("h1")?.textContent ?? "",
      said: host.textContent ?? "",
    };
  };

  it("titles a subscription by its catalogue and locates a folder source", () => {
    const rows = [
      {
        name: "a folder subscribed under a relative alias",
        row: {
          name: ".",
          repo: null,
          repoKey: null,
          repoIdentity: null,
          path: ".",
          resolvedPath: "/home/me/dev/kendex",
          meta: { name: "kendex" },
        },
        title: "kendex",
        shown: `${LOCAL_FOLDER_LABEL} · /home/me/dev/kendex`,
      },
      {
        name: "a repository with nothing read from its catalogue",
        row: {},
        title: "Kit",
        shown: "Acme/Kit",
      },
    ];
    expect(rows).toHaveLength(2);
    for (const each of rows) {
      const header = drawn(each.row);
      expect(header.title, each.name).toBe(each.title);
      expect(header.said, each.name).toContain(each.shown);
    }
    // The folder says so; the repository has no folder to say it about.
    expect(drawn(rows[1].row).said).not.toContain(LOCAL_FOLDER_LABEL);
  });
});
