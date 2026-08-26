// Installing from a subscription: the one action that writes packages into
// a scope, kept beside the store so the store body stays the subscription
// lifecycle.
import { toast } from "sonner";
import type {
  AvailablePackage,
  HarnessId,
  InstallItem,
  Scope,
} from "@/bindings";
import { commands } from "@/bindings";
import {
  catalogKey,
  refreshDownstream,
  subscription,
} from "./marketplaces-shared";

/** One install: what to put where, and — when the picker was used — which
 * tools it lands on and how the files get there. Each half of `delivery` is
 * sent only when it was actually chosen; a `null` leaves the scope's own
 * install defaults to decide, which the engine brings up to date against
 * this machine as it plans. */
export interface InstallRequest {
  scope: Scope;
  source: string;
  items: InstallItem[];
  bundle?: string | null;
  destination?: Scope | null;
  delivery?: {
    harnesses: HarnessId[] | null;
    method: "symlink" | "copy" | null;
  };
}

/** What this action writes back into the store. */
interface Installed {
  packages: Record<string, AvailablePackage[]>;
}

type Set = (partial: object | ((state: Installed) => object)) => void;

export function installActions(set: Set) {
  return {
    install: async ({
      scope,
      source,
      items,
      bundle = null,
      destination,
      delivery,
    }: InstallRequest) => {
      set({ busy: true });
      let response: Awaited<ReturnType<typeof commands.marketplaceInstall>>;
      try {
        response = await commands.marketplaceInstall(
          scope,
          source,
          items,
          bundle,
          destination ?? null,
          false,
          delivery?.harnesses ?? null,
          delivery?.method ?? null,
        );
      } finally {
        set({ busy: false });
      }
      if (response.status === "error") {
        toast.error(response.error);
        return false;
      }
      // The command answers with the refreshed package list for this
      // subscription, so the table flips to Installed without a second query.
      const key = catalogKey(subscription(destination ?? scope, source));
      set((state) => ({
        packages: { ...state.packages, [key]: response.data },
        // Member states in every open set moved with this install.
        bundles: {},
        error: null,
      }));
      const what = bundle
        ? `the ${bundle} bundle`
        : items.length === 1
          ? items[0].name
          : `${items.length} packages`;
      toast.success(`Installed ${what}`);
      await refreshDownstream();
      return true;
    },
  };
}
