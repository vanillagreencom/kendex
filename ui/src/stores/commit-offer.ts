import { toast } from "sonner";
import { create } from "zustand";
import {
  type CommitOfferScan,
  commands,
  type ProjectFlag,
  type ProjectOffer,
  type Refused,
} from "@/bindings";
import {
  committedToast,
  NOTHING_TO_COMMIT_TOAST,
  pushedToast,
} from "@/lib/copy-commit-offer";
import { useProblemsStore } from "./problems";

/** Which of the three the person picked. `leave` is not one: leaving is
 *  dismissing, and nothing runs for it. */
export type Route = "commit" | "push" | "pr";

/** Where the dialog is. Each state carries exactly what its own copy
 *  draws, so no view has to guess which fields apply to it. */
export type Stage =
  | { at: "offer" }
  | { at: "busy"; step: Route }
  | {
      at: "commitRefused";
      refused: Refused;
      stillStaged: number | null;
      /** The commit refused on the `pr` route and the branch kendex made
       *  is gone again, which the state says in one added line. */
      abandoned: boolean;
      /** The commit refused on the `pr` route and the way back refused
       *  too: the checkout is still on the new branch, and this carries
       *  the words of the step that would have put it back. Null on every
       *  other path. */
      notPutBack: Refused | null;
    }
  | { at: "branchRefused"; refused: Refused }
  /** Nothing was left to commit on the `pr` route and the switch back
   *  then refused: no commit to report, and the checkout is still on the
   *  branch kendex made, so kendex stops there. */
  | { at: "notPutBack"; refused: Refused }
  | {
      at: "pushRefused";
      refused: Refused;
      sha: string;
      branch: string;
      files: number;
      /** The recovery is to put the commit on a branch of its own, so it
       *  is offered only where a pull request can be opened and only where
       *  the commit is not already on such a branch. */
      canOpen: boolean;
      before: string | null;
    }
  | { at: "pullRequestRefused"; refused: Refused; sha: string; branch: string }
  | {
      at: "opened";
      sha: string;
      branch: string;
      url: string;
      /** The checkout moved to the branch, which the `pr` route does and
       *  the refused-push recovery does not. */
      moved: boolean;
      /** Where the checkout did not move, the commit the person can put
       *  their branch back to. */
      before: string | null;
      from: string;
    };

interface CommitOfferState {
  /** One entry per project the last write reached, first in line first.
   *  Each is asked on its own and answered on its own. */
  queue: ProjectOffer[];
  /** Projects where kendex owns changed files and no offer can be made.
   *  The Projects page draws these on the cards. */
  flagged: ProjectFlag[];
  stage: Stage;
  route: Route;
  message: string;
  /** Why the scan behind a write could not say what this project holds, or
   *  null. Held rather than shown: the scan runs inside the write's own
   *  `finally`, so it can fail while the guided install is still reporting
   *  where the packages went, and a problems dialog over that install is
   *  the second unordered modal `lib/asks-first.ts` exists to stop. The
   *  dialog says it when this question's turn comes. */
  scanFailure: string | null;
  /** Whether a scan a write started is still out. What one of them read is
   *  not the last word on these projects while another is running, so the
   *  question waits — `lib/asks-first.ts` holds that condition, like every
   *  other one in the order. */
  scanning: boolean;
  enqueue: (roots: string[]) => Promise<void>;
  /** Drop everything held about one project folder: the offer waiting on
   *  it and the flag its card draws. Called when that folder stops being
   *  a project kendex tracks — it is reconnected somewhere else, or it is
   *  removed — because both are questions about files at a path nothing
   *  points at any more. */
  forget: (root: string) => void;
  /** The held scan failure has been reported; drop it. */
  scanFailureSaid: () => void;
  pick: (route: Route) => void;
  setMessage: (message: string) => void;
  run: () => Promise<void>;
  openPullRequest: () => Promise<void>;
  /** Leaving the files as diffs, which dismissing the dialog also is. */
  leave: () => void;
}

/** The choices this offer carries, in the order the design fixes. */
export function routesFor(offer: ProjectOffer): Route[] {
  const routes: Route[] = ["commit"];
  if (offer.push === null) routes.push("push");
  // Where a pull request is already open for this branch, `pr` is not
  // offered: the branch already has one.
  if (offer.pullRequest === null && offer.openNumber === null)
    routes.push("pr");
  return routes;
}

/** Roots a [`forget`] took out while a scan about them was in flight.
 *
 *  `forget` can only drop what is already here, and the scan behind a
 *  write answers later: one started before a project was reconnected or
 *  removed lands afterwards holding an offer and a flag for the old
 *  folder, and putting those back is the prompt the forget existed to
 *  end. So the answer is filtered here too, and a root asked about again
 *  — the same folder registered afresh — leaves this set at the ask. */
const forgotten = new Set<string>();

export const useCommitOfferStore = create<CommitOfferState>((set, get) => {
  /** Take the project at the head of the line off it, closing the dialog
   *  when nobody is left. */
  const advance = () => {
    const queue = get().queue.slice(1);
    set({
      queue,
      stage: { at: "offer" },
      route: "commit",
      message: queue[0]?.message ?? "",
    });
  };

  /** A transport failure is not an answer about the repository: it says
   *  nothing about what was committed, so it opens the problems dialog
   *  rather than closing over the project in silence. */
  const transport = (message: string) => {
    useProblemsStore.getState().showError({
      title: "Couldn't reach kendex",
      message,
      steps: ["Try again", "If it keeps happening, restart kendex"],
    });
    set({ stage: { at: "offer" } });
  };

  const head = () => get().queue[0];

  // The scans overlap, so only the latest one that started may answer, and
  // nothing is asked until the last of them has.
  //
  // `writingRepo` asks for this scan in a `finally` and does not wait on
  // it, and one reader action runs `writingRepo` many times — the guided
  // install writes once per place and once per marketplace inside each —
  // so several scans are in flight at once and they can come back in any
  // order. An older answer read the projects before the newer one's write,
  // and putting its file lists back is the stale reading this queue must
  // not carry: `commitOfferCommit` re-derives the generated paths when it
  // runs, so a commit would take files the dialog never listed. It is
  // dropped whole, failure included — every one of these scans is asked
  // about the same roots, every project this machine tracks, so a later
  // answer is an answer about all of them.
  //
  // Latest-wins alone would still leave the first answer on screen while a
  // later write's scan is out: the reader would be offered a project's
  // files as they stood one write ago, and the commit re-derives what is
  // there when it runs. So `scanning` says a scan is still out and the
  // question waits for it.
  let started = 0;
  let answered = 0;

  /** The last step of both pull-request routes. `moved` says whether the
   *  checkout is now on the branch, which the `pr` route does and the
   *  refused-push recovery deliberately does not. */
  const open = async (
    offer: ProjectOffer,
    sha: string,
    branch: string,
    files: number,
    moved: boolean,
    before: string | null,
    from: string,
  ) => {
    const repo = offer.repo;
    if (repo === null) return;
    set({ stage: { at: "busy", step: "pr" } });
    const opened = await commands.commitOfferOpenPullRequest(
      repo,
      branch,
      from,
      get().message,
      files,
    );
    if (opened.status === "error") return transport(opened.error);
    if (opened.data.kind === "refused") {
      set({
        stage: {
          at: "pullRequestRefused",
          refused: opened.data.refused,
          sha,
          branch,
        },
      });
      return;
    }
    set({
      stage: {
        at: "opened",
        sha,
        branch,
        url: opened.data.url,
        moved,
        before,
        from,
      },
    });
  };

  return {
    queue: [],
    flagged: [],
    stage: { at: "offer" },
    route: "commit",
    message: "",
    scanFailure: null,
    scanning: false,

    enqueue: async (roots) => {
      if (roots.length === 0) return;
      for (const root of roots) forgotten.delete(root);
      const ticket = ++started;
      set({ scanning: true });
      const response = await commands.commitOfferScan(roots);
      // A scan that started before one already answered says nothing about
      // what the projects hold now.
      if (ticket < answered) return;
      answered = ticket;
      // Another write's scan started after this one and has not come back,
      // so this answer is one write behind what the projects hold.
      const scanning = started > answered;
      if (response.status === "error") {
        // The write itself landed and was reported by its own caller; a
        // read behind it that failed is said here and nowhere else — held
        // until this question's turn, because this scan runs inside a
        // write's `finally` and the install that started it may still be
        // on screen saying what it did.
        set({ scanFailure: response.error, scanning });
        return;
      }
      const found: CommitOfferScan = {
        ...response.data,
        offers: response.data.offers.filter(
          (offer) => !forgotten.has(offer.root),
        ),
        flagged: response.data.flagged.filter(
          (flag) => !forgotten.has(flag.root),
        ),
      };
      const { queue, stage } = get();
      // A project already in the line keeps its PLACE, and takes the fresh
      // reading of what it holds.
      //
      // Keeping the older reading is what lets a commit take files the
      // dialog never listed: two writes can reach one project in quick
      // succession — the guided install writes per place and per
      // marketplace, each through its own `writingRepo` — and the commit
      // re-derives the generated paths when it runs, so it takes what is
      // there then, not what was listed when the first scan answered.
      //
      // The head is left alone while it is being answered: that answer is
      // in flight against the offer on screen, and swapping it underneath
      // would change what the running step is about. Its own next scan
      // corrects it.
      const fresh = new Map(found.offers.map((offer) => [offer.root, offer]));
      const answering = stage.at !== "offer";
      const kept = queue.map((offer, at) =>
        at === 0 && answering ? offer : (fresh.get(offer.root) ?? offer),
      );
      const waiting = new Set(kept.map((offer) => offer.root));
      const added = found.offers.filter((offer) => !waiting.has(offer.root));
      const next = [...kept, ...added];
      set({
        queue: next,
        flagged: found.flagged,
        // A read of these projects that did land is the answer about them,
        // so an earlier scan's held failure has nothing left to report.
        scanFailure: null,
        scanning,
        // The reader's own typing is theirs: a fresh reading of the files
        // says nothing about the message they are part-way through.
        message: queue.length > 0 ? get().message : (next[0]?.message ?? ""),
      });
    },

    forget: (root) => {
      forgotten.add(root);
      const { queue } = get();
      const kept = queue.filter((offer) => offer.root !== root);
      if (kept.length === queue.length) {
        set({ flagged: get().flagged.filter((flag) => flag.root !== root) });
        return;
      }
      set({
        queue: kept,
        flagged: get().flagged.filter((flag) => flag.root !== root),
        // The dialog on screen was about the offer at the head. Where that
        // is the one being dropped, the answer in progress is about a
        // folder nothing tracks, so the question starts again at whoever
        // is next rather than swapping under the reader's answer.
        ...(queue[0]?.root === root
          ? {
              stage: { at: "offer" as const },
              route: "commit" as const,
              message: kept[0]?.message ?? "",
            }
          : {}),
      });
    },

    scanFailureSaid: () => set({ scanFailure: null }),

    pick: (route) => set({ route }),
    setMessage: (message) => set({ message }),

    leave: () => advance(),

    run: async () => {
      const offer = head();
      if (!offer) return;
      const { route, message } = get();
      set({ stage: { at: "busy", step: route } });
      // Read before the commit: it is the commit a recovery would put the
      // branch back to, and after the commit it is no longer HEAD.
      const previous = await commands.commitOfferPreviousHead(offer.root);
      const before = previous.status === "ok" ? previous.data : null;
      if (route === "pr") {
        const started = await commands.commitOfferStartBranch(
          offer.root,
          offer.newBranch,
        );
        if (started.status === "error") return transport(started.error);
        if (started.data.kind === "refused") {
          // The pull-request segment is gone from that state, so the
          // picked one moves to a route it still offers.
          set({
            stage: { at: "branchRefused", refused: started.data.refused },
            route: "commit",
          });
          return;
        }
      }
      const committed = await commands.commitOfferCommit(offer.root, message);
      if (committed.status === "error") return transport(committed.error);
      if (committed.data.kind === "nothing") {
        if (route === "pr") {
          // The checkout was switched to the new branch before the commit
          // and no commit landed on it, so without this the branch would
          // be left empty with the checkout on it.
          const back = await commands.commitOfferAbandonBranch(
            offer.root,
            offer.newBranch,
          );
          if (back.status === "error") return transport(back.error);
          if (back.data.kind === "refused") {
            set({ stage: { at: "notPutBack", refused: back.data.refused } });
            return;
          }
        }
        toast.info(NOTHING_TO_COMMIT_TOAST);
        advance();
        return;
      }
      if (committed.data.kind === "refused") {
        const { refused, stillStaged } = committed.data;
        let abandoned = false;
        if (route === "pr") {
          // The branch carries no commit of its own, so kendex clears its
          // own leftover: back to where the person was, and the empty
          // branch removed.
          const back = await commands.commitOfferAbandonBranch(
            offer.root,
            offer.newBranch,
          );
          if (back.status === "error") return transport(back.error);
          if (back.data.kind === "refused") {
            // Both refusals are shown: the commit's own, and the one that
            // left the checkout on the new branch.
            set({
              stage: {
                at: "commitRefused",
                refused,
                stillStaged,
                abandoned: false,
                notPutBack: back.data.refused,
              },
            });
            return;
          }
          abandoned = true;
        }
        set({
          stage: {
            at: "commitRefused",
            refused,
            stillStaged,
            abandoned,
            notPutBack: null,
          },
        });
        return;
      }
      const { sha, files } = committed.data;
      if (route === "commit") {
        toast.success(committedToast(files));
        advance();
        return;
      }
      const remote = offer.remote;
      if (remote === null) {
        // Neither push route is offered without a remote, so reaching
        // here would be the dialog offering what the scan refused.
        transport("kendex has no remote to push to in this project.");
        return;
      }
      const branch = route === "pr" ? offer.newBranch : offer.branch;
      set({ stage: { at: "busy", step: "push" } });
      const pushed = await commands.commitOfferPush(
        offer.root,
        remote,
        branch,
        route === "pr" ? false : offer.tracked,
      );
      if (pushed.status === "error") return transport(pushed.error);
      if (pushed.data.kind === "refused") {
        set({
          stage: {
            at: "pushRefused",
            refused: pushed.data.refused,
            sha,
            branch,
            files,
            // On the `pr` route the commit is already on a branch of its
            // own, which is what the recovery would have made.
            canOpen: route !== "pr" && offer.pullRequest === null,
            before,
          },
        });
        return;
      }
      if (route === "push") {
        toast.success(pushedToast(files));
        advance();
        return;
      }
      await open(offer, sha, branch, files, true, null, offer.branch);
    },

    openPullRequest: async () => {
      const offer = head();
      const stage = get().stage;
      if (!offer || stage.at !== "pushRefused") return;
      const remote = offer.remote;
      if (remote === null) return;
      set({ stage: { at: "busy", step: "pr" } });
      const pushed = await commands.commitOfferPushHead(
        offer.root,
        remote,
        offer.newBranch,
      );
      if (pushed.status === "error") return transport(pushed.error);
      if (pushed.data.kind === "refused") {
        set({ stage: { ...stage, refused: pushed.data.refused } });
        return;
      }
      await open(
        offer,
        stage.sha,
        offer.newBranch,
        stage.files,
        false,
        stage.before,
        stage.branch,
      );
    },
  };
});
