// Installing from a subscription: the one action that writes packages into
// a scope, kept beside the store so the store body stays the subscription
// lifecycle — and the second question an install can leave behind, about
// what a package does to the repository.
import { toast } from "sonner";
import type {
  AvailablePackage,
  Disclosure,
  InstallItem,
  Scope,
} from "@/bindings";
import { commands } from "@/bindings";
import type { Choice } from "@/components/marketplaces/harness-select";
import {
  repoEffectsAppliedToast,
  repoEffectsDeclinedToast,
  repoEffectsFailedTitle,
  repoEffectsSaidTitle,
  repoEffectsWithheldToast,
} from "@/lib/copy-repo-effects";
import { rescanEverything } from "@/lib/rescan";
import { sayUndone } from "@/lib/undone";
import {
  catalogKey,
  droppedSetCaches,
  subscription,
} from "./marketplaces-shared";
import { useProblemsStore } from "./problems";

/** One install: what to put where, and — when the picker was used — what
 * the picker settled: which tools it lands on, how the files get there, and
 * which optional dependencies it takes. `harnesses` and `method` are sent
 * only when actually chosen; a `null` leaves the scope's own install
 * defaults to decide, which the engine brings up to date against this
 * machine as it plans. The picker's whole answer travels as one value —
 * two fields carrying the same choice is how two call sites end up sending
 * different installs. */
interface InstallRequest {
  scope: Scope;
  source: string;
  items: InstallItem[];
  bundle?: string | null;
  destination?: Scope | null;
  delivery?: Choice;
}

/** The repository effects an install brought, waiting on their own yes:
 * the scope they would change, and the packages still to be asked about,
 * first in line first. Each one is asked on its own and answered on its
 * own, and the answer is spent there — nothing stores it. */
interface PendingEffects {
  scope: Scope;
  queue: Disclosure[];
}

/** What this action writes back into the store. */
interface Installed {
  packages: Record<string, AvailablePackage[]>;
  pendingEffects: PendingEffects | null;
}

/** The install half of the marketplaces store: the write, and the second
 * question it can leave behind. */
export interface InstallActions {
  install: (request: InstallRequest) => Promise<boolean>;
  /** The repository effects the last install left waiting on a yes, or
   * null — what the effects dialog reads. */
  pendingEffects: PendingEffects | null;
  applyRepoEffect: () => Promise<boolean>;
  declineRepoEffect: () => void;
}

type Set = (partial: object | ((state: Installed) => object)) => void;
type Get = () => { pendingEffects: PendingEffects | null };

/** The last line with anything in it, or nothing said at all. */
const spoken = (lines: string[]) =>
  lines.filter((line) => line.trim() !== "").at(-1);

export function installActions(set: Set, get: Get): InstallActions {
  /** Take the package at the head of the line off it, closing the dialog
   *  when nobody is left. */
  const advance = () => {
    const pending = get().pendingEffects;
    if (!pending) return;
    const queue = pending.queue.slice(1);
    set({
      pendingEffects: queue.length > 0 ? { ...pending, queue } : null,
    });
  };

  return {
    pendingEffects: null,

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
          // Empty is the answer, not the absence of one: an extra nobody
          // ticked is not installed.
          delivery?.optional ?? [],
        );
      } finally {
        set({ busy: false });
      }
      if (response.status === "error") {
        toast.error(response.error);
        return false;
      }
      const target = destination ?? scope;
      // The command answers with the refreshed package list for this
      // subscription, so the table flips to Installed without a second query.
      const key = catalogKey(subscription(target, source));
      const { shown, withheld } = response.data.repoEffects;
      set((state) => ({
        packages: { ...state.packages, [key]: response.data.packages },
        // Member states in every set this install touched moved with it,
        // in the open set and in the list of sets alike.
        ...droppedSetCaches(),
        error: null,
        // The files are in; what a package does to the repository is a
        // second question, asked once the install is reported.
        pendingEffects:
          shown.length > 0 ? { scope: target, queue: shown } : null,
      }));
      const what = bundle
        ? `the ${bundle} bundle`
        : items.length === 1
          ? items[0].name
          : `${items.length} packages`;
      toast.success(`Installed ${what}`);
      // Whatever an install's plan took away, and what its uninstaller
      // ran on the way out. Said, never asked about: the second question
      // this dialog exists for is about arming, and this already happened.
      sayUndone(response.data.undone);
      for (const held of withheld) {
        toast.info(repoEffectsWithheldToast(held.name, held.reason));
      }
      await rescanEverything();
      return true;
    },

    /** Run the installer of the package at the head of the line, here and
     *  now, and show its own last word: an installer that deliberately
     *  armed nothing says so and exits clean, and a canned "Applied" over
     *  it would tell the person the repository is armed when it is not.
     *  A failure is the one account of a possibly half-written repository,
     *  so it opens the error dialog rather than flashing past in a toast;
     *  the line moves on either way, the package staying installed. */
    applyRepoEffect: async () => {
      const pending = get().pendingEffects;
      if (!pending) return false;
      const [head] = pending.queue;
      set({ busy: true });
      let response: Awaited<ReturnType<typeof commands.repoEffectsApply>>;
      try {
        response = await commands.repoEffectsApply(
          pending.scope,
          head.declared,
        );
      } finally {
        set({ busy: false });
      }
      if (response.status === "error") {
        useProblemsStore.getState().showError({
          title: repoEffectsFailedTitle(head.name),
          message: response.error,
        });
        advance();
        return false;
      }
      advance();
      const { stdout, stderr } = response.data;
      // The last line it printed, not the last element: relay keeps the
      // installer's trailing blank lines, and an empty toast says nothing.
      const summary = spoken(stdout) ?? spoken(stderr);
      toast.success(summary ?? repoEffectsAppliedToast(head.name));
      // An installer can exit clean and still have skipped its work — the
      // reason, and what to do about it, go to stderr while the summary
      // goes to stdout. A toast is one line, so the account a person has
      // to act on gets the dialog the app opens for exactly that.
      if (spoken(stderr) !== undefined) {
        useProblemsStore.getState().showError({
          title: repoEffectsSaidTitle(head.name),
          message: [...stderr, ...stdout].join("\n"),
        });
      }
      return true;
    },

    /** Leave the package installed and its effect unapplied — a state,
     *  not a failure. */
    declineRepoEffect: () => {
      const pending = get().pendingEffects;
      if (!pending) return;
      toast.info(repoEffectsDeclinedToast(pending.queue[0].name));
      advance();
    },
  };
}
