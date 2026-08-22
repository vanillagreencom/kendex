// Subscribing, unsubscribing, and turning a subscription off: the three
// mutations that rewrite a scope's kendex.toml without installing anything.
//
// Each tells the editor the moment its command answers, before the tables
// are re-read. The Customize tab may be holding a whole copy of the file
// that was just rewritten, and every await between the write and that
// telling is a window where saving the copy puts the old file back.
import { toast } from "sonner";
import type { CatalogSummary, MarketplaceRow, Scope } from "@/bindings";
import { commands } from "@/bindings";
import { manifestRewritten } from "./manifest-sync";
import {
  dropCatalogCaches,
  dropSummariesHeldBy,
  isRepoKey,
  openLead,
  refreshDownstream,
} from "./marketplaces-shared";
import { refusesForUnsaved } from "./unsaved-first";

/** The slice of the store these mutations read and write. */
interface SubscriptionSlice {
  rows: MarketplaceRow[];
  summaries: Record<string, CatalogSummary>;
  busy: boolean;
  error: string | null;
  load: () => Promise<void>;
}

type Set = (partial: object | ((state: SubscriptionSlice) => object)) => void;
type Get = () => SubscriptionSlice;

export function subscriptionOps(set: Set, get: Get) {
  return {
    subscribe: async (
      scope: Scope,
      reference: string,
      name: string | null,
    ): Promise<boolean> => {
      // Subscribing writes this place's kendex.toml.
      if (refusesForUnsaved(scope)) return false;
      set({ busy: true });
      try {
        const response = await commands.marketplaceSubscribe(
          scope,
          reference,
          name,
        );
        if (response.status === "error") {
          // The dialog shows the refusal beside the input; no toast on top.
          set({ error: response.error });
          return false;
        }
        await manifestRewritten(scope);
        set({ error: null });
        toast.success(`Subscribed to '${response.data.name}'`);
        for (const note of response.data.notes) toast.message(note);
        dropCatalogCaches(set);
        // A repository page may now have a subscription to carry on as,
        // under whatever spelling the dialog was submitted with — every
        // repository summary re-reads, and only one such page can be open.
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
      } finally {
        set({ busy: false });
      }
    },

    unsubscribe: async (
      scope: Scope,
      source: string,
      keep: boolean,
      discardEdits: boolean,
    ): Promise<boolean> => {
      // Unsubscribing rewrites this place's kendex.toml.
      if (refusesForUnsaved(scope)) return false;
      set({ busy: true });
      try {
        const response = await commands.marketplaceUnsubscribe(
          scope,
          source,
          keep,
          discardEdits,
        );
        if (response.status === "error") {
          set({ error: response.error });
          return false;
        }
        await refreshDownstream(scope);
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
        return true;
      } finally {
        set({ busy: false });
      }
    },

    toggle: async (
      scope: Scope,
      source: string,
      enabled: boolean,
    ): Promise<void> => {
      // Turning a source off rewrites this place's kendex.toml.
      if (refusesForUnsaved(scope)) return;
      set({ busy: true });
      try {
        const response = await commands.sourceToggle(scope, source, enabled);
        if (response.status === "error") {
          toast.error(response.error);
          return;
        }
        await refreshDownstream(scope);
        dropCatalogCaches(set);
        dropSummariesHeldBy(set, get().rows, scope, source);
        await get().load();
      } finally {
        set({ busy: false });
      }
    },
  };
}
