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
  enqueue: (roots: string[]) => Promise<void>;
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

    enqueue: async (roots) => {
      if (roots.length === 0) return;
      const response = await commands.commitOfferScan(roots);
      if (response.status === "error") {
        // The write itself landed and was reported by its own caller; a
        // read behind it that failed is said here and nowhere else — held
        // until this question's turn, because this scan runs inside a
        // write's `finally` and the install that started it may still be
        // on screen saying what it did.
        set({ scanFailure: response.error });
        return;
      }
      const found: CommitOfferScan = response.data;
      const { queue } = get();
      // A project already in the line keeps its place and its answer in
      // progress: kendex asks at most once per project.
      const waiting = new Set(queue.map((offer) => offer.root));
      const added = found.offers.filter((offer) => !waiting.has(offer.root));
      const next = [...queue, ...added];
      set({
        queue: next,
        flagged: found.flagged,
        message: queue.length > 0 ? get().message : (next[0]?.message ?? ""),
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
