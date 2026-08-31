// Acting on a source as a whole — switching it on or off, and fetching
// what every subscription now offers — kept beside the store so the store
// body stays the subscription lifecycle.
import { toast } from "sonner";
import type { Scope } from "@/bindings";
import { commands } from "@/bindings";
import { rescanEverything } from "@/lib/rescan";
import { dropCatalogCaches } from "./marketplaces-shared";

/** What these actions need back from the store. */
interface Sources {
  load: () => Promise<void>;
}

type Set = (partial: object) => void;

export function sourceActions(set: Set, get: () => Sources) {
  return {
    toggle: async (scope: Scope, source: string, enabled: boolean) => {
      const response = await commands.sourceToggle(scope, source, enabled);
      if (response.status === "error") {
        toast.error(response.error);
        return;
      }
      // Turning a holder on or off changes which subscription a repository
      // page carries on as, so every derived read goes.
      dropCatalogCaches(set);
      await get().load();
      await rescanEverything();
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
        } else {
          toast.error(response.error);
        }
      } finally {
        set({ busy: false });
      }
    },
  };
}
