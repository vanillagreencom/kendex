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
//
// The problems dialog is one modal for the whole app, so every question
// behind it waits: a repository effect whose installer failed says so
// there and the line moves on, and the next package's block drawn over
// that account is the pair this order exists to stop — as is a scan
// failure written over it, which loses the first account outright.
//
// A question also waits for its own answer to be finished. The commit
// offer's is read by a scan per write, and one reader action writes many
// times, so an offer drawn while another scan is out states a project's
// files as they stood one write ago. An offer already being answered — a
// step running, a refusal on screen, a held package's setup — is past
// that point: the scan leaves the offer at the head alone while its
// answer is on screen, so it has nothing to say about that offer, and
// waiting on it would take the dialog down mid-answer.
//
// The macOS app's first-launch question, whether to install the kendex
// command, is last: it is asked once, it loses nothing by waiting, and it
// waits for the terms screen too, which covers the whole window and is
// answered before anything else is.
import { useCommitOfferStore } from "@/stores/commit-offer";
import { useInstallFlow } from "@/stores/install-flow";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useProblemsStore } from "@/stores/problems";
import { useTermsStore } from "@/stores/terms";

/** The questions, in the order they are asked. The commit offer's scan
 *  failure is one of them rather than a detail of the offer: it has its own
 *  modal, and it is said before the offer it arrived beside. */
export type Question =
  | "install"
  | "repoEffects"
  | "commitOfferFailure"
  | "commitOffer"
  | "commandLink";

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
  const scanning = useCommitOfferStore((s) => s.scanning);
  const problems = useProblemsStore((s) => s.dialog.open);
  const offered = useCommitOfferStore((s) => s.queue.length > 0);
  const answering = useCommitOfferStore(
    (s) => s.queue.length > 0 && s.stage.at !== "offer",
  );
  // Answered, not merely unread: a terms read that has not landed or that
  // failed is no evidence the screen will stay down.
  const termsAnswered = useTermsStore((s) => s.state?.ask === false);
  switch (question) {
    case "install":
      return true;
    case "repoEffects":
      return !installing && !problems;
    case "commitOfferFailure":
      return !installing && !effects && !problems && !scanning;
    case "commitOffer":
      return (
        !installing &&
        !effects &&
        !scanFailure &&
        !problems &&
        (!scanning || answering)
      );
    case "commandLink":
      return (
        termsAnswered &&
        !installing &&
        !effects &&
        !scanFailure &&
        !problems &&
        !scanning &&
        !offered
      );
  }
}
