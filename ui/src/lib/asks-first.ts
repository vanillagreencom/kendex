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
//
// Everything a question can put on screen belongs to that question, its
// failures included: the commit offer's scan failure is reported through
// the problems dialog, which is a modal like any other, so the offer waits
// for its own failure to be said and dismissed. A dialog adding a
// condition of its own instead is how this came back twice — the order is
// whole here or it is not an order.
import { useCommitOfferStore } from "@/stores/commit-offer";
import { useInstallFlow } from "@/stores/install-flow";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useProblemsStore } from "@/stores/problems";

/** The questions, in the order they are asked. The commit offer's scan
 *  failure is one of them rather than a detail of the offer: it has its own
 *  modal, and it is said before the offer it arrived beside. */
export type Question =
  | "install"
  | "repoEffects"
  | "commitOfferFailure"
  | "commitOffer";

/** Whether this question may be on screen now: every question ahead of it
 *  has to be silent first, and so does anything it has itself put up.
 *
 *  A hook rather than a predicate over a snapshot, because each dialog has
 *  to re-render when the one ahead of it closes — that is the moment it
 *  becomes the reader's next question. */
export function useMayAsk(question: Question): boolean {
  const installing = useInstallFlow((s) => s.ask !== null);
  const effects = useMarketplacesStore((s) => s.pendingEffects !== null);
  // The commit offer's own two: a scan failure waiting to be said, and the
  // dialog saying it. A write that reached several projects can leave an
  // offer and a failure together, and drawing both is the pair this order
  // exists to stop.
  const scanFailure = useCommitOfferStore((s) => s.scanFailure !== null);
  const problems = useProblemsStore((s) => s.dialog.open);
  switch (question) {
    case "install":
      return true;
    case "repoEffects":
      return !installing;
    case "commitOfferFailure":
      return !installing && !effects;
    case "commitOffer":
      return !installing && !effects && !scanFailure && !problems;
  }
}
