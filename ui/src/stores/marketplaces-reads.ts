// The marketplaces store's cached reads: each answer lands under its own
// key, and each failure under its own error key, so a later success
// elsewhere never erases why a different read produced nothing.
import type {
  AboutView,
  AvailablePackage,
  BundleDetail,
  Catalog,
  CatalogSummary,
} from "@/bindings";
import { commands } from "@/bindings";
import {
  bundleKey,
  catalogKey,
  readErrorKey,
  readGeneration,
  without,
} from "./marketplaces-shared";

/** The slice of the store these reads write. */
export interface ReadCaches {
  packages: Record<string, AvailablePackage[]>;
  summaries: Record<string, CatalogSummary>;
  about: Record<string, AboutView>;
  bundles: Record<string, BundleDetail>;
  readErrors: Record<string, string>;
}

type Set = (fn: (state: ReadCaches) => Partial<ReadCaches>) => void;

export function catalogReads(set: Set) {
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
  set: Set,
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
