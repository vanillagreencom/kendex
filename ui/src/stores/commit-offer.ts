import { toast } from "sonner";
import { create } from "zustand";
import {
  type ChangeSelection,
  commands,
  type ProjectBaseline,
  type ProjectFlag,
  type ProjectOffer,
  type Refused,
} from "@/bindings";
import {
  committedToast,
  droppedToast,
  NOTHING_TO_COMMIT_TOAST,
  pushedToast,
} from "@/lib/copy-commit-offer";
import { askingAgain, forgetRoot, isForgotten } from "@/lib/forgotten-roots";
import { useProblemsStore } from "./problems";

/** Which of the three the person picked. `leave` is not one: leaving is
 *  dismissing, and nothing runs for it. */
export type Route = "commit" | "push" | "pr";

/** Which pending changes the picked route is about.
 *
 *  `action` is the work the write that opened this offer did; `all` is
 *  everything kendex has pending in the project, this action's work
 *  included. The choice is put to the reader only where the two would make
 *  different commits — [`ProjectOffer.choice`] says so — and `action` is
 *  what an offer a write opened starts on, because that write is what the
 *  reader just did. */
export type Scoped = "action" | "all";

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
  stage: Stage;
  route: Route;
  /** Which pending changes the picked route is about. Reset to `action`
   *  whenever the head of the line changes: the choice belongs to the offer
   *  in front of the reader, not to the store. */
  scoped: Scoped;
  /** Whether the reader has said yes to committing the earlier edits that
   *  ride along with the action's own work, on the files the offer names as
   *  carrying both. Nothing labelled as one action's work commits an
   *  earlier change without this. Reset with the head of the line. */
  accepted: boolean;
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
  /** What each project held before the write that is running now, kept from
   *  the FIRST write of a reader's action until that project's question has
   *  been answered.
   *
   *  One reader action runs many writes — the guided install writes once per
   *  place and once per marketplace inside each — and a reading taken before
   *  the second write would report the first write's own files as work that
   *  was already there. So the first reading of each project stands, and
   *  [`noteBaseline`] reads only the projects it has none for.
   *
   *  No view draws this. It is here rather than in a closure so that it is
   *  one thing the store owns, reset with the rest of the store. */
  baselines: Record<string, ProjectBaseline>;
  /** The project whose offer a person opened themselves, while that offer
   *  is still on screen. A scan started by an earlier write can answer
   *  after they open it, and its reading is attributed to that write — put
   *  in front of them it would answer a question they did not ask, with a
   *  scope they did not choose. `null` once that offer is answered. */
  asked: string | null;
  /** Read what each of these projects holds now, before a write. Kept per
   *  project until that project's question has been answered, so the offer
   *  at the end of a guided install is about the install rather than about
   *  its last step. */
  noteBaseline: (roots: string[]) => Promise<void>;
  enqueue: (roots: string[]) => Promise<void>;
  /** Drop everything held about one project folder: the offer waiting on
   *  it and the flag its card draws. Called when that folder stops being
   *  a project kendex tracks — it is reconnected somewhere else, or it is
   *  removed — because both are questions about files at a path nothing
   *  points at any more. */
  forget: (root: string) => void;
  /** Put one project's offer in front of the reader because they asked for
   *  it, not because a write left it behind. Nothing is attributed to an
   *  action, so every pending change is theirs to choose from, and the
   *  setting that turns off asking does not apply — they are asking.
   *  Answers with the reason where no offer can be made. */
  openFor: (root: string) => Promise<OpenedFor>;
  /** The held scan failure has been reported; drop it. */
  scanFailureSaid: () => void;
  pick: (route: Route) => void;
  /** Pick which pending changes the route is about. */
  scope: (scoped: Scoped) => void;
  /** Say yes to the earlier edits riding along with this action's work. */
  accept: (accepted: boolean) => void;
  setMessage: (message: string) => void;
  run: () => Promise<void>;
  openPullRequest: () => Promise<void>;
  /** Leaving the files as diffs, which dismissing the dialog also is.
   *
   *  Dismissing is an answer, and it lasts: nothing puts this project's
   *  changes back in front of the reader until a write changes them again
   *  or the reader opens the review themselves. The passive read behind the
   *  project cards never enqueues, so a refresh — start-up, focus, a scan —
   *  cannot bring a dismissed question back. */
  leave: () => void;
}

/** What asking for one project's offer answered with, for the surface that
 *  asked. */
export type OpenedFor =
  | { at: "offer" }
  /** Nothing kendex owns has changed here any more. */
  | { at: "nothing" }
  /** The offer cannot be made in this project's state. The flag is the
   *  reason the read itself gave, carried rather than re-derived: the page
   *  drew its own row from an earlier read, and this one is newer. */
  | { at: "blocked"; flag: ProjectFlag }
  /** The read itself would not run. */
  | { at: "failed"; error: string };

/** Which pending changes a step should carry, from the offer and what the
 *  reader picked.
 *
 *  `all` is every pending change kendex owns here. `action` names the paths
 *  the write did, and core narrows those to what it still covers when the
 *  step runs — so the commit behind the label is the label.
 *
 *  An offer with nothing attributed to an action — one a person opened
 *  themselves — has no action set, and asking for one would send an empty
 *  list. It sends `all`, which is what that reader is choosing from. */
export function selectionOf(state: {
  queue: ProjectOffer[];
  scoped: Scoped;
}): ChangeSelection {
  const offer = state.queue[0];
  if (!offer || state.scoped === "all" || offer.actionPaths.length === 0)
    return { kind: "all" };
  return { kind: "only", paths: offer.actionPaths };
}

/** Whether the primary action may run: a commit labelled as one action's
 *  work never carries an earlier change the reader has not said yes to.
 *  Every other state is free to run.
 *
 *  What the yes is about is the earlier work, not which label the commit
 *  carries. Picking "all pending changes" IS that answer: the reader asked
 *  for everything pending by name. Every other route to a commit that
 *  includes work the action did not do waits for the checkbox — including
 *  an offer with no choice to draw, where the one commit on offer carries
 *  the earlier changes in those files whatever the label says. The dialog
 *  draws the answer wherever this can hold, so the gate is never one a
 *  reader cannot free. */
export function ready(state: {
  queue: ProjectOffer[];
  scoped: Scoped;
  accepted: boolean;
}): boolean {
  const offer = state.queue[0];
  if (!offer) return true;
  if (offer.choice && state.scoped === "all") return true;
  return offer.tangled.length === 0 || state.accepted;
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
  /** Forget the readings for projects with nothing left to answer, so the
   *  next action reads them afresh. Only once no scan is still out: a
   *  project is not absent from the line while an answer about it is still
   *  on its way. */
  const settle = () => {
    if (get().scanning) return;
    const waiting = new Set(get().queue.map((offer) => offer.root));
    set({
      baselines: Object.fromEntries(
        Object.entries(get().baselines).filter(([root]) => waiting.has(root)),
      ),
    });
  };

  /** Drop one project's reading: its question has been answered, so a write
   *  that changes it again reads it afresh and what is pending then is that
   *  write's own work against whatever the reader chose to leave.
   *
   *  Named apart from the store's own `forget`, which is about a folder
   *  that stopped being a project rather than about a question that has
   *  been answered. */
  const spent = (root: string) => {
    const { [root]: _gone, ...rest } = get().baselines;
    set({ baselines: rest });
  };

  /** Take the project at the head of the line off it, closing the dialog
   *  when nobody is left. */
  const advance = () => {
    const gone = get().queue[0];
    const queue = get().queue.slice(1);
    if (gone) spent(gone.root);
    set({
      queue,
      stage: { at: "offer" },
      route: "commit",
      scoped: "action",
      accepted: false,
      message: queue[0]?.message ?? "",
      // Answered, so the next reading of this project stands.
      ...(gone && gone.root === get().asked ? { asked: null } : {}),
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
    stage: { at: "offer" },
    route: "commit",
    scoped: "action",
    accepted: false,
    message: "",
    scanFailure: null,
    scanning: false,
    baselines: {},
    asked: null,

    noteBaseline: async (roots) => {
      const held = get().baselines;
      const missing = roots.filter((root) => !(root in held));
      if (missing.length === 0) return;
      const response = await commands.commitOfferBaseline(missing);
      // A reading that would not run says nothing about these projects, and
      // nothing is recorded for them. The offer after the write then finds
      // no reading to compare against and treats every pending change there
      // as the write's own — which over-reports rather than labelling
      // somebody else's work as this action's.
      if (response.status === "error") return;
      set({
        baselines: {
          ...get().baselines,
          ...Object.fromEntries(response.data.map((one) => [one.root, one])),
        },
      });
    },

    enqueue: async (roots) => {
      if (roots.length === 0) return;
      askingAgain(roots);
      const ticket = ++started;
      set({ scanning: true });
      const held = get().baselines;
      const response = await commands.commitOfferScan(
        roots,
        roots.flatMap((root) => (root in held ? [held[root]] : [])),
      );
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
        // A reading is spent when the write it was taken for has been read
        // for, answered or not. Kept past that, the next write in the same
        // project compares against a reading taken before somebody else's
        // action and reports that action's files as its own — which is the
        // one thing this whole comparison exists to stop. Settled on the
        // same rule as a scan that landed: a project with no offer waiting
        // has no question left to answer.
        settle();
        return;
      }
      // A folder that stopped being a project while this scan was out is
      // not one to put back on screen: `forgotten-roots` owns that rule for
      // every store that holds something per project.
      const found: ProjectOffer[] = response.data.filter(
        (offer) => !isForgotten(offer.root),
      );
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
      const fresh = new Map(found.map((offer) => [offer.root, offer]));
      const answering = stage.at !== "offer";
      // The offer a person opened themselves is theirs: it attributes
      // nothing to an action and covers everything pending, which is what
      // they asked to see. A scan an earlier write started answers about
      // that write, and swapping it in would put its scope under their
      // question. Their own next write reads the project afresh.
      const opened = get().asked;
      // A project already in the line takes the fresh reading, which is the
      // new write's: its files, and its own account of what that write did
      // against what was already pending. A queued offer left alone would
      // still name the earlier write's work as "this action".
      const kept = queue.map((offer, at) =>
        at === 0 && (answering || offer.root === opened)
          ? offer
          : (fresh.get(offer.root) ?? offer),
      );
      const waiting = new Set(kept.map((offer) => offer.root));
      const added = found.filter((offer) => !waiting.has(offer.root));
      const next = [...kept, ...added];
      set({
        queue: next,
        // A read of these projects that did land is the answer about them,
        // so an earlier scan's held failure has nothing left to report.
        scanFailure: null,
        scanning,
        // The reader's own typing is theirs: a fresh reading of the files
        // says nothing about the message they are part-way through.
        message: queue.length > 0 ? get().message : (next[0]?.message ?? ""),
      });
      settle();
    },

    openFor: async (root) => {
      const response = await commands.commitOfferOpen(root);
      if (response.status === "error") {
        return { at: "failed", error: response.error };
      }
      if (response.data.kind === "nothing") return { at: "nothing" };
      if (response.data.kind === "blocked")
        return { at: "blocked", flag: response.data.flag };
      const offer = response.data.offer;
      // Ahead of whatever a write left behind: the reader asked for this
      // one, and it is the project they are looking at. A project already
      // in the line is not asked about twice, and the fresh reading — which
      // attributes nothing to an action, because none opened it — is the
      // one that stands.
      const rest = get().queue.filter((each) => each.root !== root);
      // No action opened this, so there is no action to scope to.
      spent(root);
      set({
        queue: [offer, ...rest],
        stage: { at: "offer" },
        route: "commit",
        scoped: "all",
        accepted: false,
        message: offer.message,
        asked: root,
      });
      return { at: "offer" };
    },

    forget: (root) => {
      forgetRoot(root);
      // The reading taken before a write goes with the folder it was taken
      // in: a question about files at a path nothing points at any more is
      // not one to keep, and holding it would compare the next write in a
      // folder registered afresh against a reading from before the move.
      spent(root);
      const { queue } = get();
      const kept = queue.filter((offer) => offer.root !== root);
      if (kept.length === queue.length) return;
      set({
        queue: kept,
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
    scope: (scoped) => set({ scoped, accepted: false }),
    accept: (accepted) => set({ accepted }),
    setMessage: (message) => set({ message }),

    leave: () => advance(),

    run: async () => {
      const offer = head();
      if (!offer) return;
      const { route, message } = get();
      // Settled before the first step and carried through every one of
      // them: the commit, the push and the pull request are three ways of
      // sending the same set, and a set that changed between them would put
      // a different commit behind the label the reader read.
      const selection = selectionOf(get());
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
      const committed = await commands.commitOfferCommit(
        offer.root,
        message,
        selection,
      );
      if (committed.status === "error") return transport(committed.error);
      if (committed.data.kind === "nothing") {
        // Which files the reader picked that the project no longer holds a
        // change for. "Nothing to commit" alone leaves them wondering what
        // became of the ones they chose, and this is the same account a
        // commit that dropped only some of them gives.
        const gone = committed.data.dropped;
        if (gone.length > 0) toast.info(droppedToast(gone));
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
      const { sha, files, dropped } = committed.data;
      // Paths the reader chose that the project no longer holds a change
      // for. Said rather than dropped in silence: they chose them, and a
      // count alone would leave them wondering which.
      if (dropped.length > 0) toast.info(droppedToast(dropped));
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
