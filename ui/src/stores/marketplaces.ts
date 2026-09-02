import { toast } from "sonner";
import { create } from "zustand";
import {
  type Catalog,
  commands,
  type MarketplaceRow,
  type Scope,
} from "@/bindings";
import {
  READ_PENDING,
  type ReadState,
  readOf,
  readOrder,
} from "@/lib/read-state";
import { rescanEverything } from "@/lib/rescan";
import { settled } from "@/lib/settled";
import { saying, sayUndone } from "@/lib/undone";
import { catalogReads } from "./marketplaces-catalog-reads";
import { type InstallActions, installActions } from "./marketplaces-install";
import {
  type CatalogCaches,
  dropCatalogCaches,
  openLead,
} from "./marketplaces-shared";
import { sourceActions } from "./marketplaces-sources";

export {
  bundleKey,
  catalogBundlesErrorKey,
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

// The cached reads come from [CatalogCaches], declared once beside the drop
// that empties them so a field cannot be renamed here alone.
interface MarketplacesState extends InstallActions, CatalogCaches {
  rows: MarketplaceRow[];
  /** How the last overview read went. A failed read leaves the rows it had,
   * and nothing may treat them as the truth about what is subscribed until
   * one lands again. Kept apart from `error` below, which
   * subscribe/unsubscribe/install also write, so a failed action never
   * rewrites the reason the stale-read notices show. */
  read: ReadState;
  busy: boolean;
  error: string | null;
  load: () => Promise<void>;
  loadPackages: (catalog: Catalog) => Promise<void>;
  loadSummary: (catalog: Catalog) => Promise<void>;
  loadAbout: (catalog: Catalog) => Promise<void>;
  loadBundle: (catalog: Catalog, name: string) => Promise<void>;
  loadCatalogBundles: (catalog: Catalog) => Promise<void>;
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
}

// Overview reads overlap — Home's mount-time load against the page's own, a
// retry button against either, every mutation re-reading behind them — and an
// older one landing last would stamp its rows current and clear the notice
// saying they are not.
const overviewOrder = readOrder();

export const useMarketplacesStore = create<MarketplacesState>((set, get) => ({
  rows: [],
  packages: {},
  about: {},
  summaries: {},
  bundles: {},
  catalogBundles: {},
  readErrors: {},
  read: READ_PENDING,
  busy: false,
  error: null,

  load: async () => {
    // A failed read — refusal or rejection, via `settled` — still answers:
    // the kept rows stay, and `read` says they are last-known.
    const ticket = overviewOrder.begin();
    const response = await settled(commands.marketplacesOverview());
    if (!overviewOrder.lands(ticket)) return;
    if (response.status === "ok") {
      set({ rows: response.data, read: readOf(response), error: null });
    } else {
      set({ read: readOf(response), error: response.error });
    }
  },

  ...catalogReads(set),

  subscribe: async (scope, reference, name) => {
    set({ busy: true });
    let response: Awaited<ReturnType<typeof commands.marketplaceSubscribe>>;
    try {
      response = await commands.marketplaceSubscribe(scope, reference, name);
    } finally {
      set({ busy: false });
    }
    if (response.status === "error") {
      // The dialog shows the refusal beside the input; no toast on top.
      set({ error: response.error });
      return false;
    }
    set({ error: null });
    toast.success(`Subscribed to '${response.data.name}'`);
    for (const note of response.data.notes) toast.message(note);
    sayUndone(response.data.undone);
    // A repository page may now have a subscription to carry on as, under
    // whatever spelling the dialog was submitted with; the dropped summaries
    // re-read and the page picks it up.
    dropCatalogCaches(set);
    await get().load();
    if (response.data.lead) {
      await openLead(scope, response.data.name, response.data.lead);
    }
    return true;
  },

  unsubscribe: async (scope, source, keep, discardEdits) => {
    set({ busy: true });
    let response: Awaited<ReturnType<typeof commands.marketplaceUnsubscribe>>;
    try {
      response = await commands.marketplaceUnsubscribe(
        scope,
        source,
        keep,
        discardEdits,
      );
    } finally {
      set({ busy: false });
    }
    if (response.status === "error") {
      set({ error: response.error });
      return false;
    }
    set({ error: null });
    toast.success(
      keep
        ? `Unsubscribed from '${source}' — its packages are yours now`
        : `Unsubscribed from '${source}'`,
    );
    saying(response);
    // A page carried on as this subscription must stop pointing at it, and
    // every other derived read goes with it.
    dropCatalogCaches(set);
    await get().load();
    await rescanEverything();
    return true;
  },

  ...sourceActions(set, get),
  ...installActions(set, get),
}));
