import { toast } from "sonner";
import { create } from "zustand";
import type { MarketplaceRow } from "@/bindings";
import {
  type AboutView,
  type AvailablePackage,
  type BundleDetail,
  type Catalog,
  type CatalogSummary,
  commands,
  type InstallItem,
  type Scope,
} from "@/bindings";
import { catalogReads } from "./marketplaces-reads";
import {
  cachedRepoCatalogs,
  catalogKey,
  dropCatalogCaches,
  refreshDownstream,
  subscription,
} from "./marketplaces-shared";
import { subscriptionOps } from "./marketplaces-subscriptions";
import { refusesForUnsaved } from "./unsaved-first";

export {
  bundleKey,
  catalogKey,
  catalogLabel,
  declaredHolder,
  marketKey,
  readErrorKey,
  repoAction,
  rowSubscribed,
  subscribedKeys,
  subscription,
} from "./marketplaces-shared";

interface MarketplacesState {
  rows: MarketplaceRow[];
  /** Each opened catalog's offered packages, by [catalogKey]. */
  packages: Record<string, AvailablePackage[]>;
  /** Each opened catalog's About report, by [catalogKey]. */
  about: Record<string, AboutView>;
  /** Each opened catalog's own account of itself, by [catalogKey] — for a
   * repository this is the read that fetches it. */
  summaries: Record<string, CatalogSummary>;
  /** Each opened curated set, by [catalogKey]::bundle. */
  bundles: Record<string, BundleDetail>;
  /** Why a read produced nothing, by the same keys — the page the person is
   * looking at says it instead of loading forever. */
  readErrors: Record<string, string>;
  loaded: boolean;
  /** Whether `rows` is the answer of the last overview read. A failed read
   * leaves the rows it had, and nothing may treat them as the truth about
   * what is subscribed until a read succeeds again. */
  rowsCurrent: boolean;
  busy: boolean;
  error: string | null;
  load: () => Promise<void>;
  loadPackages: (catalog: Catalog) => Promise<void>;
  loadSummary: (catalog: Catalog) => Promise<void>;
  loadAbout: (catalog: Catalog) => Promise<void>;
  loadBundle: (catalog: Catalog, name: string) => Promise<void>;
  subscribe: (
    scope: Scope,
    reference: string,
    name: string | null,
  ) => Promise<boolean>;
  unsubscribe: (
    scope: Scope,
    source: string,
    keep: boolean,
    discardEdits: boolean,
  ) => Promise<boolean>;
  toggle: (scope: Scope, source: string, enabled: boolean) => Promise<void>;
  checkForUpdates: () => Promise<void>;
  install: (opts: {
    scope: Scope;
    source: string;
    items: InstallItem[];
    bundle?: string | null;
    destination?: Scope | null;
  }) => Promise<boolean>;
}

export const useMarketplacesStore = create<MarketplacesState>((set, get) => ({
  rows: [],
  packages: {},
  about: {},
  summaries: {},
  bundles: {},
  readErrors: {},
  loaded: false,
  rowsCurrent: false,
  busy: false,
  error: null,

  load: async () => {
    const response = await commands.marketplacesOverview();
    if (response.status === "ok") {
      set({
        rows: response.data,
        loaded: true,
        rowsCurrent: true,
        error: null,
      });
    } else {
      set({ loaded: true, rowsCurrent: false, error: response.error });
    }
  },

  ...catalogReads(set),

  ...subscriptionOps(set, get),

  checkForUpdates: async () => {
    set({ busy: true });
    try {
      const response = await commands.sourcesRefresh();
      if (response.status === "ok") {
        for (const warning of response.data) toast.message(warning);
        // A fetch can move any subscription to a new commit; everything
        // derived from catalog bytes re-reads.
        dropCatalogCaches(set);
        await get().load();
        for (const repo of cachedRepoCatalogs(get().summaries)) {
          void get().loadSummary(repo);
        }
      } else {
        toast.error(response.error);
      }
    } finally {
      set({ busy: false });
    }
  },

  install: async ({ scope, source, items, bundle = null, destination }) => {
    // The install writes the destination's kendex.toml, so unsaved
    // customization for that place refuses it — before the flag goes up,
    // or a refusal would leave every control waiting on nothing.
    if (refusesForUnsaved(destination ?? scope)) return false;
    set({ busy: true });
    let response: Awaited<ReturnType<typeof commands.marketplaceInstall>>;
    try {
      response = await commands.marketplaceInstall(
        scope,
        source,
        items,
        bundle,
        destination ?? null,
        false,
      );
    } catch (thrown) {
      set({ busy: false });
      throw thrown;
    }
    if (response.status === "error") {
      set({ busy: false });
      toast.error(response.error);
      return false;
    }
    // The command answers with the refreshed package list for this
    // subscription, so the table flips to Installed without a second query.
    const key = catalogKey(subscription(destination ?? scope, source));
    set((state) => ({
      packages: { ...state.packages, [key]: response.data },
      // Member states in every open set moved with this install.
      bundles: {},
      error: null,
    }));
    const what = bundle
      ? `the ${bundle} bundle`
      : items.length === 1
        ? items[0].name
        : `${items.length} packages`;
    toast.success(`Installed ${what}`);
    // Busy stays up through the sync: it is what holds the Customize save
    // down, and the manifest this install rewrote is only handed to the
    // editor inside refreshDownstream. Lowering it first reopens the very
    // window the flag exists to close.
    try {
      await refreshDownstream(destination ?? scope);
    } finally {
      set({ busy: false });
    }
    return true;
  },
}));
