import { toast } from "sonner";
import { create } from "zustand";
import {
  type Catalog,
  commands,
  type InstallItem,
  type MarketplaceRow,
  type Scope,
} from "@/bindings";
import {
  READ_PENDING,
  type ReadState,
  readOf,
  readOrder,
} from "@/lib/read-state";
import { writingRepo } from "@/lib/rescan";
import { settled } from "@/lib/settled";
import { saying, sayUndone } from "@/lib/undone";
import { catalogReads } from "./marketplaces-catalog-reads";
import { type InstallActions, installActions } from "./marketplaces-install";
import {
  type CatalogCaches,
  dropCatalogCaches,
  openLead,
} from "./marketplaces-shared";
import { sourceActions } from "./marketplaces-sources";

export {
  bundleKey,
  catalogBundlesErrorKey,
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

/** Subscribing either declared a source under an alias or was refused. */
export type SubscribeOutcome = { name: string } | { error: string };

/** Unsubscribing either happened or was refused. The same shape, for the
 * same reason: a caller learns the outcome from what it was handed, never
 * by reading `error` back out of the store. That slot is written for a
 * dialog to display and cleared by every landing overview read, so a read
 * landing in the gap leaves a caller with nothing to report. */
export type UnsubscribeOutcome = { done: true } | { error: string };

// The cached reads come from [CatalogCaches], declared once beside the drop
// that empties them so a field cannot be renamed here alone.
interface MarketplacesState extends InstallActions, CatalogCaches {
  rows: MarketplaceRow[];
  /** How the last overview read went. A failed read leaves the rows it had,
   * and nothing may treat them as the truth about what is subscribed until
   * one lands again. Kept apart from `error` below, which
   * subscribe/unsubscribe/install also write, so a failed action never
   * rewrites the reason the stale-read notices show. */
  read: ReadState;
  busy: boolean;
  /** The last refusal, for a dialog to display. Written here, read only by
   * the surface showing it — never by a caller deciding what happened. */
  error: string | null;
  /** Emptied by whichever surface is about to show its own refusals, so a
   * message left by another action cannot open under it. */
  clearError: () => void;
  load: () => Promise<void>;
  loadPackages: (catalog: Catalog) => Promise<void>;
  loadSummary: (catalog: Catalog) => Promise<void>;
  loadAbout: (catalog: Catalog) => Promise<void>;
  loadBundle: (catalog: Catalog, name: string) => Promise<void>;
  loadCatalogBundles: (catalog: Catalog) => Promise<void>;
  /** What subscribing answered, handed straight to the caller: the alias
   * the subscription was declared under, or the engine's refusal. The
   * refusal is also left in `error` for the dialog that shows it beside
   * its input, but no caller may read it back from there — `load` clears
   * that slot on every landing overview read, so a concurrent one lands in
   * the gap and the caller finds nothing. */
  subscribe: (
    scope: Scope,
    reference: string,
    name: string | null,
  ) => Promise<SubscribeOutcome>;
  /** Install from a marketplace nobody subscribes to yet: the subscription
   * is what makes the packages installable, so the one click makes it
   * first, personally, and then installs. Announced before the click by
   * [SUBSCRIBE_TO_INSTALL_MEANS] — the row never subscribes in silence. */
  subscribeAndInstall: (repo: string, items: InstallItem[]) => Promise<boolean>;
  unsubscribe: (
    scope: Scope,
    source: string,
    keep: boolean,
    discardEdits: boolean,
  ) => Promise<UnsubscribeOutcome>;
  toggle: (scope: Scope, source: string, enabled: boolean) => Promise<void>;
  checkForUpdates: () => Promise<void>;
}

// Overview reads overlap — Home's mount-time load against the page's own, a
// retry button against either, every mutation re-reading behind them — and an
// older one landing last would stamp its rows current and clear the notice
// saying they are not.
const overviewOrder = readOrder();

export const useMarketplacesStore = create<MarketplacesState>((set, get) => ({
  rows: [],
  packages: {},
  about: {},
  summaries: {},
  bundles: {},
  catalogBundles: {},
  readErrors: {},
  read: READ_PENDING,
  busy: false,
  error: null,

  clearError: () => set({ error: null }),

  load: async () => {
    // A failed read — refusal or rejection, via `settled` — still answers:
    // the kept rows stay, and `read` says they are last-known.
    const ticket = overviewOrder.begin();
    const response = await settled(commands.marketplacesOverview());
    if (!overviewOrder.lands(ticket)) return;
    if (response.status === "ok") {
      set({ rows: response.data, read: readOf(response), error: null });
    } else {
      set({ read: readOf(response), error: response.error });
    }
  },

  ...catalogReads(set),

  // The subscription's own report goes through `repo_effects::write`, which
  // is why the outcome carries an account to say — so the machine is read
  // again behind it like any other write. `lib/rescan.ts` holds the rule.
  subscribe: (scope, reference, name) =>
    writingRepo(async () => {
      set({ busy: true });
      let response: Awaited<ReturnType<typeof commands.marketplaceSubscribe>>;
      try {
        response = await commands.marketplaceSubscribe(scope, reference, name);
      } finally {
        set({ busy: false });
      }
      if (response.status === "error") {
        // The dialog shows the refusal beside the input; no toast on top.
        // The same words go back to the caller, which is the only way a
        // caller may have them.
        set({ error: response.error });
        return { error: response.error };
      }
      set({ error: null });
      toast.success(`Subscribed to '${response.data.name}'`);
      for (const note of response.data.notes) toast.message(note);
      sayUndone(response.data.undone);
      // A repository page may now have a subscription to carry on as, under
      // whatever spelling the dialog was submitted with; the dropped summaries
      // re-read and the page picks it up.
      dropCatalogCaches(set);
      await get().load();
      if (response.data.lead) {
        await openLead(scope, response.data.name, response.data.lead);
      }
      return { name: response.data.name };
    }),

  subscribeAndInstall: async (repo, items) => {
    // Personal, deliberately: the row that offered this install was not
    // showing a place to install into, so the one place every install can
    // fall back to is the person's own. The line above the table says so
    // before the click. A project subscription is still the dialog's job,
    // where the place is asked for.
    const scope: Scope = { scope: "global" };
    const outcome = await get().subscribe(scope, repo, null);
    if ("error" in outcome) {
      // Said from the outcome, never read back out of the shared slot: a
      // concurrent overview read clears that slot, and a click that
      // installed nothing would then report nothing either.
      toast.error(outcome.error);
      // There is no input here to show the refusal beside, so the slot it
      // was left in is emptied — otherwise the next Subscribe dialog opens
      // already complaining about a repository nobody typed.
      set({ error: null });
      return false;
    }
    return get().install({ scope, source: outcome.name, items });
  },

  unsubscribe: (scope, source, keep, discardEdits) =>
    writingRepo(async () => {
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
        return { error: response.error };
      }
      set({ error: null });
      toast.success(
        keep
          ? `Unsubscribed from '${source}' — its packages are yours now`
          : `Unsubscribed from '${source}'`,
      );
      saying(response);
      // A page carried on as this subscription must stop pointing at it, and
      // every other derived read goes with it.
      dropCatalogCaches(set);
      await get().load();
      return { done: true };
    }),

  ...sourceActions(set, get),
  ...installActions(set, get),
}));
