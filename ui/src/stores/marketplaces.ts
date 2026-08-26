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
import { MARKETPLACES_NEEDS_CHECK_NOTE } from "@/lib/copy-marketplaces";
import { settled } from "@/lib/settled";
import { landings } from "./landings";
import { type InstallRequest, installActions } from "./marketplaces-install";
import {
  bundleKey,
  catalogKey,
  dropCatalogCaches,
  isRepoKey,
  openLead,
  readErrorKey,
  readGeneration,
  refreshDownstream,
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

/** A read lands only if no cache drop happened while it ran: an answer
 * from before the drop describes a checkout that may no longer be the one
 * installed from. A stale answer is not stored; the read is asked once
 * more under the new generation, since the empty slot it would have
 * filled never changed and nothing else will ask. */
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
  const began = readGeneration();
  const response = await read();
  if (began !== readGeneration()) {
    return settle(set, field, key, errorKey, read);
  }
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
  /** Why the last overview read failed, or null — written only by `load`.
   * The shared `error` above is also set by subscribe/unsubscribe/install,
   * so a failed action would otherwise rewrite the reason the stale-read
   * notices show. */
  checkError: string | null;
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
  install: (request: InstallRequest) => Promise<boolean>;
}

// Overview reads overlap — Home's mount-time load against the page's own,
// or a mutation's re-read — and a slow early one landing last would stamp
// pre-mutation rows current. Every write goes through subscribe/unsubscribe
// re-reading via load(), so read ordering alone covers it.
const overviewLandings = landings();

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
  checkError: null,

  load: async () => {
    // A failed read — refusal or rejection, via `settled` — still answers:
    // `loaded` comes up, `rowsCurrent` does not, and the kept rows stay.
    const ticket = overviewLandings.begin();
    const response = await settled(commands.marketplacesOverview());
    if (!overviewLandings.land(ticket)) return;
    if (response.status === "ok") {
      set({
        rows: response.data,
        loaded: true,
        rowsCurrent: true,
        error: null,
        checkError: null,
      });
    } else {
      set({
        loaded: true,
        rowsCurrent: false,
        error: response.error,
        checkError: response.error,
      });
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
    dropCatalogCaches(set);
    // A repository page may now have a subscription to carry on as, under
    // whatever spelling the dialog was submitted with — every repository
    // summary re-reads, and only one such page can be open.
    set((state) => ({
      summaries: Object.fromEntries(
        Object.entries(state.summaries).filter(([key]) => !isRepoKey(key)),
      ),
    }));
    await get().load();
    if (response.data.lead) {
      await openLead(scope, response.data.name, response.data.lead);
    }
    return true;
  },

  unsubscribe: async (scope, source, keep, discardEdits) => {
    // The action boundary owns the guarantee: a dialog opened while rows
    // were current can still confirm after a failed re-read left them
    // stale — refusing here covers every trigger at once.
    if (!get().rowsCurrent) {
      set({ error: MARKETPLACES_NEEDS_CHECK_NOTE });
      return false;
    }
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
    dropCatalogCaches(set);
    // A page carried on as this subscription must stop pointing at it.
    set({ summaries: {} });
    await get().load();
    await refreshDownstream();
    return true;
  },

  ...sourceActions(set, get),
  ...installActions(set),
}));
