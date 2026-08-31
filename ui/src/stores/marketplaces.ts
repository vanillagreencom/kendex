import { toast } from "sonner";
import { create } from "zustand";
import {
  type AboutView,
  type AvailablePackage,
  type BundleDetail,
  type Catalog,
  type CatalogSummary,
  commands,
  type MarketplaceRow,
  type Scope,
} from "@/bindings";
import { READ_PENDING, type ReadState, readOf } from "@/lib/read-state";
import { rescanEverything } from "@/lib/rescan";
import { settled } from "@/lib/settled";
import { type InstallActions, installActions } from "./marketplaces-install";
import {
  bundleKey,
  catalogKey,
  dropCatalogCaches,
  openLead,
  readErrorKey,
  without,
} from "./marketplaces-shared";
import { sourceActions } from "./marketplaces-sources";

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

// The marketplaces store's cached reads: each answer lands under its own
// key, and each failure under its own error key, so a later success
// elsewhere never erases why a different read produced nothing.

/** The slice of the store these reads write. */
interface ReadCaches {
  packages: Record<string, AvailablePackage[]>;
  summaries: Record<string, CatalogSummary>;
  about: Record<string, AboutView>;
  bundles: Record<string, BundleDetail>;
  readErrors: Record<string, string>;
}

type SetReads = (fn: (state: ReadCaches) => Partial<ReadCaches>) => void;

function catalogReads(set: SetReads) {
  return {
    loadPackages: (catalog: Catalog) => {
      const key = catalogKey(catalog);
      return settle(set, "packages", key, readErrorKey(key, "packages"), () =>
        commands.marketplacePackages(catalog),
      );
    },
    loadSummary: (catalog: Catalog) => {
      const key = catalogKey(catalog);
      return settle(set, "summaries", key, readErrorKey(key, "summary"), () =>
        commands.marketplaceSummary(catalog),
      );
    },
    loadAbout: (catalog: Catalog) => {
      const key = catalogKey(catalog);
      return settle(set, "about", key, readErrorKey(key, "about"), () =>
        commands.marketplaceAbout(catalog),
      );
    },
    loadBundle: (catalog: Catalog, name: string) => {
      const key = bundleKey(catalog, name);
      return settle(set, "bundles", key, key, () =>
        commands.marketplaceBundle(catalog, name),
      );
    },
  };
}

/** One cached read: the answer lands under its key, a failure under its
 * error key. */
async function settle<F extends Exclude<keyof ReadCaches, "readErrors">>(
  set: SetReads,
  field: F,
  key: string,
  errorKey: string,
  read: () => Promise<
    | { status: "ok"; data: ReadCaches[F][string] }
    | { status: "error"; error: string }
  >,
): Promise<void> {
  const response = await read();
  if (response.status === "ok") {
    set((state) => ({
      [field]: { ...state[field], [key]: response.data },
      readErrors: without(state.readErrors, errorKey),
    }));
  } else {
    set((state) => ({
      readErrors: { ...state.readErrors, [errorKey]: response.error },
    }));
  }
}

interface MarketplacesState extends InstallActions {
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

export const useMarketplacesStore = create<MarketplacesState>((set, get) => ({
  rows: [],
  packages: {},
  about: {},
  summaries: {},
  bundles: {},
  readErrors: {},
  read: READ_PENDING,
  busy: false,
  error: null,

  load: async () => {
    // A failed read — refusal or rejection, via `settled` — still answers:
    // the kept rows stay, and `read` says they are last-known.
    const response = await settled(commands.marketplacesOverview());
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
