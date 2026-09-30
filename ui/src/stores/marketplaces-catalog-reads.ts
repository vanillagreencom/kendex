// The marketplaces store's cached reads: each answer lands under its own
// key, and each failure under its own error key, so a later success
// elsewhere never erases why a different read produced nothing.
import {
  type Catalog,
  commands,
  type Scope,
  type SourceReadRefused,
} from "@/bindings";
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
  // Partial arrivals re-run consumers' effects. Share each outstanding read
  // in its generation, including the replacement a stale answer asks for.
  const pending = new Map<
    string,
    {
      generation: number;
      promise: Promise<void>;
      status: "pending" | "settled";
    }
  >();
  const readOnce = <F extends Exclude<keyof CatalogCaches, "readErrors">>(
    field: F,
    key: string,
    errorKey: string,
    read: () => Promise<
      | { status: "ok"; data: CatalogCaches[F][string] }
      | { status: "error"; error: SourceReadRefused | string }
    >,
    request: "direct" | "replacement" = "direct",
  ): Promise<void> => {
    const generation = catalogDrops.since();
    const held = pending.get(errorKey);
    // An old generation joins even an already-settled replacement. A
    // direct request can retry failures or explicitly refresh a result.
    if (
      held?.generation === generation &&
      (held.status === "pending" || request === "replacement")
    )
      return held.promise;
    const promise = settle(set, field, key, errorKey, read, generation, () =>
      readOnce(field, key, errorKey, read, "replacement"),
    ).finally(() => {
      const current = pending.get(errorKey);
      if (current?.promise === promise) current.status = "settled";
    });
    pending.set(errorKey, { generation, promise, status: "pending" });
    return promise;
  };
  return {
    loadPackages: (catalog: Catalog) => {
      const key = catalogKey(catalog);
      return readOnce("packages", key, readErrorKey(key, "packages"), () =>
        commands.marketplacePackages(catalog),
      );
    },
    loadSummary: (catalog: Catalog) => {
      const key = catalogKey(catalog);
      return readOnce("summaries", key, readErrorKey(key, "summary"), () =>
        commands.marketplaceSummary(catalog),
      );
    },
    loadAbout: (catalog: Catalog) => {
      const key = catalogKey(catalog);
      return readOnce("about", key, readErrorKey(key, "about"), () =>
        commands.marketplaceAbout(catalog),
      );
    },
    loadCatalogBundles: (catalog: Catalog) => {
      return readOnce(
        "catalogBundles",
        catalogKey(catalog),
        catalogBundlesErrorKey(catalog),
        () => commands.marketplaceBundles(catalog),
      );
    },
    loadBundle: (catalog: Catalog, name: string, destination: Scope | null) => {
      const key = bundleKey(catalog, name, destination);
      return readOnce("bundles", key, key, () =>
        commands.marketplaceBundle(catalog, name, destination),
      );
    },
  };
}

/** One cached read: the answer lands under its key, a failure under its
 * error key.
 *
 * A read that outlives a cache drop is not stored, ok and error alike.
 * It joins the current generation's read or starts it when no other
 * consumer has asked. Discarding alone would leave the emptied slot blank. */
async function settle<F extends Exclude<keyof CatalogCaches, "readErrors">>(
  set: SetReads,
  field: F,
  key: string,
  errorKey: string,
  read: () => Promise<
    | { status: "ok"; data: CatalogCaches[F][string] }
    | { status: "error"; error: SourceReadRefused | string }
  >,
  began: number,
  reread: () => Promise<void>,
): Promise<void> {
  // `settled` so a transport rejection lands as this read's own error
  // rather than escaping: these loaders are called with `void` from
  // effects, so a rejection would leave the slot empty, no reason under
  // its key, and the page loading forever with nothing to retry from.
  const response = await settled(read());
  if (catalogDrops.stale(began)) {
    return reread();
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
