// @vitest-environment jsdom
// A Community page carries on as a subscription the moment the summary it
// fetched names one. That summary is cached under the REQUESTED repository's
// key, so anything looking it up by the subscription it produced finds
// nothing — which is how one page came to read the catalogue's declared name
// in its breadcrumb and the bare alias in its own body.
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { CatalogSummary, MarketplaceRow, Scope } from "@/bindings";
import { UNNAMED_MARKETPLACE } from "@/lib/copy-marketplaces";
import { useCommunityStore } from "@/stores/community";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { catalogKey, subscription } from "@/stores/marketplaces-shared";
import { mount } from "@/test/dom";
import { useCatalog } from "./use-catalog";

const REQUESTED = { by: "repo" as const, repo: "vanillagreencom/kendex" };
const PLACE: Scope = { scope: "project", root: "/home/me/dev" };

const summary = (over: Partial<CatalogSummary> = {}): CatalogSummary => ({
  provenance: "vanillagreencom/kendex",
  repoKey: "vanillagreencom/kendex",
  repoIdentity: "github.com/vanillagreencom/kendex",
  commit: null,
  meta: { name: "kendex" },
  mode: null as unknown as CatalogSummary["mode"],
  counts: {},
  warning: null,
  subscription: { scope: PLACE, source: "." },
  ...over,
});

/** What the hook answers for a page opened on the repository. */
function resolved(): { catalog: string; name: string } {
  const seen = { catalog: "", name: "" };
  function Probe() {
    const { catalog, display } = useCatalog(REQUESTED);
    seen.catalog = catalog.by;
    seen.name = display.name;
    return null;
  }
  mount(<Probe />);
  return seen;
}

beforeEach(() => {
  vi.clearAllMocks();
  useCommunityStore.setState({ directory: null });
  useMarketplacesStore.setState({
    rows: [],
    summaries: {},
    readErrors: {},
  });
});

describe("what a converted Community page calls its marketplace", () => {
  it("keeps the summary that discovered the subscription", () => {
    useMarketplacesStore.setState({
      summaries: { [catalogKey(REQUESTED)]: summary() },
    });

    // The page is a subscription now, and its name is still the one the
    // catalogue declares — never the alias `.` the subscription is keyed
    // under, which is what a lookup by the converted catalog would leave.
    expect(resolved()).toEqual({ catalog: "subscription", name: "kendex" });
  });

  // The declaring row is the better answer once the overview lands, and it
  // must agree with the summary rather than replace it with an alias.
  it("agrees with the declaring row once the overview has landed", () => {
    const row: MarketplaceRow = {
      scope: PLACE,
      name: ".",
      repo: null,
      repoKey: null,
      repoIdentity: null,
      provenance: "/home/me/dev",
      path: ".",
      resolvedPath: "/home/me/dev",
      rev: null,
      commit: null,
      enabled: true,
      counts: null,
      meta: { name: "kendex" },
      mode: null,
      recordsUnreadable: false,
    };
    useMarketplacesStore.setState({
      rows: [row],
      summaries: { [catalogKey(REQUESTED)]: summary() },
    });

    expect(resolved()).toEqual({ catalog: "subscription", name: "kendex" });
  });

  // A curated set and an offered package are opened FROM the marketplace
  // page, which hands them the subscription it became — so their own
  // `requested` is that subscription, while the summary that discovered it
  // is still cached under the repository the reader browsed. Before the
  // overview rows land they have neither row nor summary under the key they
  // hold, and the page read `Unnamed marketplace` under a breadcrumb
  // reading the declared name.
  it("recovers the summary for a page reached from a converted one", () => {
    useMarketplacesStore.setState({
      summaries: { [catalogKey(REQUESTED)]: summary() },
    });

    const seen = { name: "" };
    function Nested() {
      // What `goToBundle`/`goToAvailablePackage` carried from the
      // marketplace page: the subscription, never the repository.
      const { display } = useCatalog(subscription(PLACE, "."));
      seen.name = display.name;
      return null;
    }
    mount(<Nested />);

    expect(seen.name).toBe("kendex");
  });

  // Nothing read and nothing declared: the alias is a relative path and
  // names nothing, so the page says so rather than showing it.
  it("never falls back to an alias that names nothing", () => {
    useMarketplacesStore.setState({
      summaries: {
        [catalogKey(REQUESTED)]: summary({ meta: null }),
      },
    });

    // The repository the summary resolved to still names it.
    expect(resolved().name).toBe("kendex");

    // With no repository behind it either, the honest answer is a word, not
    // a path fragment.
    useMarketplacesStore.setState({
      summaries: {
        [catalogKey(REQUESTED)]: summary({ meta: null, provenance: "" }),
      },
    });
    expect(resolved().name).toBe(UNNAMED_MARKETPLACE);
  });
});
