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
      return settle(
        set,
        "packages",
        key,
        readErrorKey(key, "packages"),
        commands.marketplacePackages(catalog),
      );
    },
    loadSummary: (catalog: Catalog) => {
      const key = catalogKey(catalog);
      return settle(
        set,
        "summaries",
        key,
        readErrorKey(key, "summary"),
        commands.marketplaceSummary(catalog),
      );
    },
    loadAbout: (catalog: Catalog) => {
      const key = catalogKey(catalog);
      return settle(
        set,
        "about",
        key,
        readErrorKey(key, "about"),
        commands.marketplaceAbout(catalog),
      );
    },
    loadBundle: (catalog: Catalog, name: string) => {
      const key = bundleKey(catalog, name);
      return settle(
        set,
        "bundles",
        key,
        key,
        commands.marketplaceBundle(catalog, name),
      );
    },
  };
}

async function settle<F extends Exclude<keyof ReadCaches, "readErrors">>(
  set: Set,
  field: F,
  key: string,
  errorKey: string,
  pending: Promise<
    | { status: "ok"; data: ReadCaches[F][string] }
    | { status: "error"; error: string }
  >,
) {
  const response = await pending;
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
