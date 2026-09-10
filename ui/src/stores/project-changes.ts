import { create } from "zustand";
import { type ChangesState, commands, type ProjectChanges } from "@/bindings";
import { askingAgain, forgetRoot, isForgotten } from "@/lib/forgotten-roots";
import {
  READ_LANDED,
  READ_PENDING,
  type ReadState,
  readOf,
  readOrder,
} from "@/lib/read-state";

/** What each tracked project has waiting for a commit.
 *
 *  The passive half of the commit offer, and the only half that runs
 *  without a write behind it. It is read on the ordinary refresh path —
 *  start-up, focus, an explicit Scan again, and behind every write — and it
 *  opens nothing: the Projects page draws a line from it, a project's own
 *  view draws the same line, and the review page draws its whole body from
 *  it. Nothing here can put a dialog on screen, which is what makes a
 *  refresh safe to run whenever the app reads the machine again.
 *
 *  It runs whatever the offer setting says. That setting decides whether
 *  kendex asks a question by itself; it does not decide whether a person
 *  may see what is pending in their own project. */
interface ProjectChangesState {
  /** One row per project the last read covered. A project the read could
   *  not derive a plan for has no row: nothing is known about it, and a row
   *  saying "no changes" would be the claim this store must not make. */
  rows: ProjectChanges[];
  read: ReadState;
  refresh: (roots: string[]) => Promise<void>;
  /** Drop what is held about one project folder. Called when that folder
   *  stops being a project kendex tracks — reconnected somewhere else, or
   *  removed — because a row about files at a path nothing points at any
   *  more is not an answer about anything. */
  forget: (root: string) => void;
}

// Reads of this standing overlap on every ordinary path — the startup
// effect against a focus rescan against the read behind a write — so the
// newest-begun read is the one that may write. `read-state.ts` states the
// rule.
const order = readOrder();

export const useProjectChangesStore = create<ProjectChangesState>(
  (set, get) => ({
    rows: [],
    read: READ_PENDING,

    refresh: async (roots) => {
      // These folders are projects again as far as any answer still out is
      // concerned: a folder registered afresh is asked about by name, and
      // `forgotten-roots` owns that rule for every store that holds
      // something per project.
      askingAgain(roots);
      // Nothing tracked is nothing to read, and a read of no projects has no
      // answer to publish: the rows stay as they are and the last read's own
      // outcome stands.
      if (roots.length === 0) {
        set({ rows: [], read: READ_LANDED });
        return;
      }
      const ticket = order.begin();
      const response = await commands.projectChangesScan(roots);
      if (!order.lands(ticket)) return;
      // A read that failed answers for nothing: the rows it had stay put,
      // headed by the surfaces as the last kendex could check. Replacing them
      // with none would be a count.
      set(
        response.status === "ok"
          ? {
              // A folder that stopped being a project while this read was out
              // is not one to put back on screen.
              rows: response.data.filter((row) => !isForgotten(row.root)),
              read: readOf(response),
            }
          : { read: readOf(response) },
      );
    },

    forget: (root) => {
      forgetRoot(root);
      set({ rows: get().rows.filter((row) => row.root !== root) });
    },
  }),
);

/** What one project has waiting, or null where the read covers no such
 *  project. Null is "nothing is known", never "nothing is pending": a
 *  project the read could not cover has no row at all. */
export const changesFor = (
  rows: ProjectChanges[],
  root: string,
): ProjectChanges | null => rows.find((row) => row.root === root) ?? null;

/** How many files kendex owns are waiting in this project, or null where
 *  no number can be given — the read has not covered it, or it failed. */
export function pendingCount(row: ProjectChanges | null): number | null {
  if (row === null) return null;
  switch (row.state.kind) {
    case "clean":
      return 0;
    case "pending":
      return row.state.files.length;
    case "unreadable":
      return null;
  }
}

/** Whether this project's state stops a commit being offered at all — the
 *  checkout is on no branch, or a git operation is in the middle of
 *  running. The review still opens: it is where those states are explained
 *  and where the pending changes stay visible. */
export function commitBlocked(row: ProjectChanges | null): boolean {
  if (row === null || row.state.kind !== "pending") return true;
  return row.state.branch === null || row.state.operation !== null;
}

/** The changed paths this project holds, or none where none are known. */
export function pendingPaths(row: ProjectChanges | null): string[] {
  return row !== null && row.state.kind === "pending" ? row.state.files : [];
}

export type { ChangesState };
