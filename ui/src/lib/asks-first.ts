// The order the app asks the questions a write leaves behind.
//
// Three of them are mounted once in `App.tsx` and can all become
// answerable at the same moment: the guided install is still reporting
// where the packages went, a package it installed wants to change the
// repository, and kendex wrote files a git project has not committed.
// Each is a modal. Two arriving together is a reader answering whichever
// happened to land on top, with a third behind it and no stated order.
//
// One order, held here and nowhere else: the install says what happened
// first, then the repository effects it brought, then what to do with the
// files it wrote. Nothing is lost by waiting — each queue keeps what it
// was given, so a question held is a question asked later.
import { useInstallFlow } from "@/stores/install-flow";
import { useMarketplacesStore } from "@/stores/marketplaces";

/** The questions, in the order they are asked. */
export type Question = "install" | "repoEffects" | "commitOffer";

/** Whether this question may be on screen now: every question ahead of it
 *  has to be silent first.
 *
 *  A hook rather than a predicate over a snapshot, because each dialog has
 *  to re-render when the one ahead of it closes — that is the moment it
 *  becomes the reader's next question. */
export function useMayAsk(question: Question): boolean {
  const installing = useInstallFlow((s) => s.ask !== null);
  const effects = useMarketplacesStore((s) => s.pendingEffects !== null);
  switch (question) {
    case "install":
      return true;
    case "repoEffects":
      return !installing;
    case "commitOffer":
      return !installing && !effects;
  }
}
