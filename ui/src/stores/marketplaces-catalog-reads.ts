// The marketplaces store's cached reads: each answer lands under its own
// key, and each failure under its own error key, so a later success
// elsewhere never erases why a different read produced nothing.
import { type Catalog, commands, type Scope } from "@/bindings";
import { settled } from "@/lib/settled";
import {
  bundleKey,
  type CatalogCaches,
  catalogBundlesErrorKey,
  catalogDrops,
  catalogKey,
  readErrorKey,
  without,
} from "./marketplaces-shared";

type SetReads = (fn: (state: CatalogCaches) => Partial<CatalogCaches>) => void;

export function catalogReads(set: SetReads) {
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
    loadCatalogBundles: (catalog: Catalog) => {
      return settle(
        set,
        "catalogBundles",
        catalogKey(catalog),
        catalogBundlesErrorKey(catalog),
        () => commands.marketplaceBundles(catalog),
      );
    },
    loadBundle: (catalog: Catalog, name: string, destination: Scope | null) => {
      const key = bundleKey(catalog, name, destination);
      return settle(set, "bundles", key, key, () =>
        commands.marketplaceBundle(catalog, name, destination),
      );
    },
  };
}

/** One cached read: the answer lands under its key, a failure under its
 * error key.
 *
 * A read that outlives a cache drop is not stored — ok and error alike, since
 * a stale failure pins the page on a superseded reason and `readDue` will not
 * retry it. The read is asked once more under the new generation rather than
 * only discarded: the slot the drop emptied has no other asker, and every
 * consumer keys on presence, so discarding alone leaves the page blank. */
async function settle<F extends Exclude<keyof CatalogCaches, "readErrors">>(
  set: SetReads,
  field: F,
  key: string,
  errorKey: string,
  read: () => Promise<
    | { status: "ok"; data: CatalogCaches[F][string] }
    | { status: "error"; error: string }
  >,
): Promise<void> {
  const began = catalogDrops.since();
  // `settled` so a transport rejection lands as this read's own error
  // rather than escaping: these loaders are called with `void` from
  // effects, so a rejection would leave the slot empty, no reason under
  // its key, and the page loading forever with nothing to retry from.
  const response = await settled(read());
  if (catalogDrops.stale(began)) {
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
