// Acting on a source as a whole — switching it on or off, and fetching
// what every subscription now offers — kept beside the store so the store
// body stays the subscription lifecycle.
import { toast } from "sonner";
import type {
  Catalog,
  CatalogSummary,
  MarketplaceRow,
  Scope,
} from "@/bindings";
import { commands } from "@/bindings";
import { MARKETPLACES_NEEDS_CHECK_NOTE } from "@/lib/copy-marketplaces";
import {
  cachedRepoCatalogs,
  dropCatalogCaches,
  dropSummariesHeldBy,
  refreshDownstream,
} from "./marketplaces-shared";

/** What these actions need back from the store. */
interface Sources {
  rows: MarketplaceRow[];
  rowsCurrent: boolean;
  summaries: Record<string, CatalogSummary>;
  load: () => Promise<void>;
  loadSummary: (catalog: Catalog) => Promise<void>;
}

type Set = (
  partial:
    | object
    | ((state: { summaries: Record<string, CatalogSummary> }) => object),
) => void;

export function sourceActions(set: Set, get: () => Sources) {
  return {
    toggle: async (scope: Scope, source: string, enabled: boolean) => {
      // The action boundary owns the guarantee: any trigger acting on a
      // row a failed read left behind is refused here, not just gated in
      // the component that happens to render it.
      if (!get().rowsCurrent) {
        toast.error(MARKETPLACES_NEEDS_CHECK_NOTE);
        return;
      }
      const response = await commands.sourceToggle(scope, source, enabled);
      if (response.status === "error") {
        toast.error(response.error);
        return;
      }
      dropCatalogCaches(set);
      dropSummariesHeldBy(set, get().rows, scope, source);
      await get().load();
      await refreshDownstream();
    },

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
  };
}
