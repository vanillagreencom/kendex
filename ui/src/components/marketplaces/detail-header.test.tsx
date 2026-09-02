// @vitest-environment jsdom
import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Catalog, DirectoryRow, MarketplaceRow } from "@/bindings";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import { MARKETPLACES_UNCONFIRMED_TITLE } from "@/lib/copy-marketplaces";
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
  path: null,
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
const render = (row: Partial<MarketplaceRow> = {}) =>
  renderToStaticMarkup(
    <DetailHeader
      requested={catalog}
      catalog={catalog}
      row={{ ...BASE, ...row }}
      summary={null}
    />,
  );

beforeEach(() => {
  stub.read = { status: "landed", error: null };
});

// The detail page selects its row from the store's retained rows, so a
// failed overview re-read leaves it drawing a subscription nobody could
// confirm — said on the page, with the retry beside it.
describe("DetailHeader for a subscription a failed read left behind", () => {
  it("says the row may be stale, with the retry", () => {
    stub.read = { status: "failed", error: "offline" };
    const html = render();
    expect(html).toContain(MARKETPLACES_UNCONFIRMED_TITLE);
    expect(html).toContain("offline");
    expect(html).toContain(TRY_AGAIN_LABEL);
  });

  it("carries no stale note over a current read", () => {
    const html = render();
    expect(html).not.toContain(MARKETPLACES_UNCONFIRMED_TITLE);
  });
});

// The repository and the homepage used to be plain text in a mono line and
// a link buried in the About tab. Both belong in the header, and both open
// the person's own browser rather than a page inside the app.
describe("the header's links out", () => {
  it("makes the repository a link to its page", () => {
    const html = render();
    expect(html).toMatch(/<button[^>]*>Acme\/Kit<\/button>/);
    expect(html).toContain("text-info");
  });

  // Not just the string: `ExternalLink` renders the URL as its own child
  // text, so asserting the text alone passes for a plain span too — and
  // "the homepage is a header link" is the claim the changelog makes.
  it("carries the catalog's homepage beside it, as a link", () => {
    const html = render({ meta: { homepage: "https://kendex.ai" } });
    expect(html).toMatch(/<button[^>]*>https:\/\/kendex\.ai<\/button>/);
  });

  it("leaves a folder as plain text, since there is no page to open", () => {
    const html = render({
      repo: null,
      repoKey: null,
      path: "/home/me/catalog",
    });
    expect(html).toContain("/home/me/catalog");
    expect(html).not.toMatch(/<button[^>]*>\/home\/me\/catalog<\/button>/);
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

// The meta line was three separator spellings in one paragraph, each part
// re-deriving whether anything preceded it. One separator, interleaved
// once, so every gap is the same gap.
describe("the header's meta line", () => {
  it("puts one separator between parts and none at either end", () => {
    const html = render({
      meta: { license: "MIT", author: "Vanilla Green" },
      commit: "abcdef0123456789",
    });
    const line = html.match(/<p class="mt-1 flex[^"]*">(.*?)<\/p>/s)?.[1] ?? "";
    const text = line.replace(/<[^>]+>/g, "").trim();
    expect(text).toBe("Acme/Kit·@ abcdef0·MIT·by Vanilla Green");
    expect(text).not.toMatch(/^·|·$/);
  });

  it("draws no line at all when there is nothing to put in it", () => {
    const html = render({ repo: null, repoKey: null });
    expect(html).not.toContain('class="mt-1 flex');
  });
});
