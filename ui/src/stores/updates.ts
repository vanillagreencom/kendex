import { toast } from "sonner";
import { create } from "zustand";
import { commands, type ItemWarning, type UpdateRow } from "@/bindings";
import { UPDATE_ERROR_TITLE } from "@/lib/copy";
import {
  nothingToUpdateToastLabel,
  UPDATE_NEEDS_CHECK_NOTE,
} from "@/lib/copy-updates";
import { READ_PENDING, type ReadState } from "@/lib/read-state";
import { rescanEverything } from "@/lib/rescan";
import { caught, settled } from "@/lib/settled";
import {
  skippedPlaces,
  updatablePlaces,
  visibleUpdates,
} from "@/lib/update-groups";
import {
  showBulkOutcome,
  showUpdateOutcome,
  startBulk,
} from "@/lib/update-outcome";
import { rowUnsettled } from "@/lib/updates-read-state";
import { useProblemsStore } from "./problems";
import { followSwitch, type PendingFollow } from "./updates-follow";
import { standingReads } from "./updates-standing";
import { writeIgnored, writeRow, writeRows } from "./updates-writes";

interface UpdatesState {
  rows: UpdateRow[];
  /** Packages whose standing could not be computed — shown, never treated
   *  as current. */
  warnings: ItemWarning[];
  /** Unix seconds of the last successful mirror fetch behind these rows,
   *  null when nothing has ever fetched. The page dates its answer from
   *  this — the check runs offline on load, so "everything is up to date"
   *  needs the age of the fetch it rests on beside it. */
  lastFetched: number | null;
  busy: boolean;
  /** True while a mirror fetch is running — the explicit "check". */
  checking: boolean;
  /** True while a read of the standing is on its way. Read off the same
   *  ticket that orders the landings, so the page-wide rule and the
   *  ordering rule cannot disagree: a mount or a return to the window
   *  reloads over rows that landed perfectly well, and every value a
   *  commit-applying action captured is about to be replaced. */
  reading: boolean;
  /** Follow switches already moved on screen whose write has not answered.
   *  Their scopes hold; every other row stays live. */
  pendingFollows: PendingFollow[];
  /** How the last read of the standing went. A failure keeps the rows it
   *  had and says why: the package page gates the Update button on this,
   *  and acting on rows we could not refresh is exactly the fail-open it
   *  closes. */
  read: ReadState;
  /** Read the standing again and land whatever it answers. Every operation
   *  that commits a change calls it once its own work is done, so the rows
   *  on screen are what actually committed. */
  reload: () => Promise<void>;
  check: () => Promise<void>;
  updateOne: (row: UpdateRow) => Promise<void>;
  /** Bring every updatable place among `rows` current — the page-level
   *  button passes every visible row, a package's button its own places. */
  updateRows: (rows: UpdateRow[]) => Promise<void>;
  setAutoUpdate: (row: UpdateRow, auto: boolean) => Promise<void>;
  setIgnored: (row: UpdateRow, ignored: boolean) => Promise<void>;
}

export const useUpdatesStore = create<UpdatesState>((set, get) => {
  const showError = (title: string, message: string) =>
    useProblemsStore.getState().showError({ title, message });

  const reportUpdate = (error: string) => showError(UPDATE_ERROR_TITLE, error);

  const { beginOwn, reload } = standingReads(set, get);

  /** What a commit-applying action says instead of running. Each captures
   *  values off the rows it was handed, so it may run only against rows a
   *  read confirmed and outside a scope a follow switch is settling in. */
  const needsCheck = () =>
    showError(UPDATE_ERROR_TITLE, UPDATE_NEEDS_CHECK_NOTE);

  return {
    rows: [],
    warnings: [],
    lastFetched: null,
    busy: false,
    checking: false,
    reading: false,
    pendingFollows: [],
    read: READ_PENDING,

    reload,

    check: async () => {
      // A check already running answers this click too; a second fetch would
      // cost the network twice for one answer.
      if (get().checking) return;
      set({ checking: true });
      const landOwn = beginOwn();
      try {
        const response = await settled(commands.updatesRefresh());
        // The fetch reads the standing after fetching every mirror, so it
        // ranks by when it lands — unless something committed while it was
        // out, which its report would not carry. The mirrors are fetched
        // either way, so an ordinary read picks them up ranked behind
        // whatever committed.
        if (!landOwn(response)) await reload();
        if (response.status === "error")
          showError(UPDATE_ERROR_TITLE, response.error);
      } finally {
        set({ checking: false });
      }
    },

    updateOne: async (row) => {
      if (rowUnsettled(get(), row)) return needsCheck();
      set({ busy: true });
      try {
        const answer = await caught(writeRow(row, reportUpdate));
        let applied = false;
        if (answer.status === "error") {
          // A transport failure rejects rather than refusing, and only
          // this catch sees it: unreported it would read as an update
          // that landed.
          reportUpdate(answer.error);
        } else if (answer.data.ok) {
          // Either command can come back held: the plan refuses to write
          // over a copy somebody changed, and saying "Updated" over that
          // is the whole point of asking the command what it did.
          showUpdateOutcome(row.name, answer.data.update);
          applied = true;
        }
        // Whatever it answered, the standing is read again: the work can
        // commit and then fail, and the rows must be what landed.
        await reload();
        if (applied) await rescanEverything();
      } finally {
        set({ busy: false });
      }
    },

    updateRows: async (wanted) => {
      const state = get();
      if (wanted.some((row) => rowUnsettled(state, row))) return needsCheck();
      set({ busy: true });
      try {
        // Edited packages are held by the engine and cannot be updated
        // this way — their row says so and offers the install beside — so
        // they are left out rather than silently surviving the click.
        // Rows that are news without an update (gone upstream, mixed
        // installs) have nothing for this button to do.
        const rows = updatablePlaces(wanted);
        const skipped = skippedPlaces(wanted).length;
        if (rows.length === 0) {
          toast.info(nothingToUpdateToastLabel(skipped));
          return;
        }
        const outcome = startBulk(skipped);
        const answer = await caught(writeRows(rows, reportUpdate, outcome));
        // A rejection escapes the sequence without touching the outcome —
        // only this catch saw it, and success must not be claimed over it.
        if (answer.status === "error") {
          reportUpdate(answer.error);
          outcome.ok = false;
        }
        await reload();
        // Counted off what the applies reported, never off the rows the
        // click covered: a place the plan held back needs attention on its
        // own row, it is not one more updated.
        // Said whether or not a place failed: the error is its own toast,
        // and what the rest of the run did to the person's packages is not
        // the error's to swallow.
        showBulkOutcome(outcome, visibleUpdates(get().rows));
        await rescanEverything();
      } finally {
        set({ busy: false });
      }
    },

    setAutoUpdate: followSwitch({
      set,
      get,
      report: (error) => showError(UPDATE_ERROR_TITLE, error),
    }),

    setIgnored: async (row, ignored) => {
      const response = await settled(writeIgnored(row, ignored));
      if (response.status === "error")
        showError(UPDATE_ERROR_TITLE, response.error);
      // The command answers with the overview it rebuilt, and this reads
      // it again anyway. That report carries this write but not one that
      // landed beside it, and a single count cannot tell an operation's
      // own commit from another's — so rather than reason about whose bump
      // was whose, the ordinary read takes it, ranked behind whatever
      // committed. The command can also persist the preference and then
      // fail building the overview, which the same read answers.
      await reload();
    },
  };
});
