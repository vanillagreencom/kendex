import { toast } from "sonner";
import { create } from "zustand";
import { commands, type ItemWarning, type UpdateRow } from "@/bindings";
import { UPDATE_ERROR_TITLE, updatedToastLabel } from "@/lib/copy";
import {
  nothingToUpdateToastLabel,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATES_ONE_AT_A_TIME_NOTE,
} from "@/lib/copy-updates";
import { READ_PENDING, type ReadState } from "@/lib/read-state";
import { rescanEverything } from "@/lib/rescan";
import { caught, settled } from "@/lib/settled";
import {
  packageCount,
  skippedPlaces,
  updatablePlaces,
} from "@/lib/update-groups";
import { rowUnsettled } from "@/lib/updates-read-state";
import { useProblemsStore } from "./problems";
import { bulkLine, noRun, sayApply } from "./updates-apply";
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
  /** True while a write that went through [holdingBusy] is running. That
   *  wrapper is the definition rather than a summary of one:
   *  `grep -rn holdingBusy ui/src` is the list, and a mutation reaching the
   *  engine another way — a marketplace install, an audit apply — does not
   *  raise this and takes no part in the exclusion below. */
  busy: boolean;
  /** True while a mirror fetch is running — the explicit "check". It and
   *  `busy` exclude each other: a fetch builds its report once, so a commit
   *  landing while it is out would be missing from it. */
  checking: boolean;
  /** True while a read of the standing is on its way. Read off the same
   *  ticket that orders the landings, so the page-wide rule and the
   *  ordering rule cannot disagree: a mount or a return to the window
   *  reloads over rows that landed perfectly well, and every value a
   *  commit-applying action captured is about to be replaced. */
  reading: boolean;
  /** Follow switches already moved on screen whose write has not answered.
   *  A flip's scope is what decides which rows the landing behind it may
   *  not be acted on from. */
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

/** How many writes are out. Counted rather than set: several paths raise
 *  `busy` now, and a `finally` writing false would drop the flag out from
 *  under a write still running — which is the moment `check` must still
 *  refuse. */
let writesOut = 0;

/** Hold the store's `busy` for as long as `work` runs.
 *
 *  Every write the exclusion covers goes through this, wherever it lives:
 *  `check` refuses on `busy` alone, so a write the flag does not cover is a
 *  check running beside it, and a report built before that commit landing
 *  after it. Paths outside this module reach it by import; `followSwitch`
 *  takes it as `holding`, since this module imports that one. */
export const holdingBusy = async <T>(work: () => Promise<T>): Promise<T> => {
  writesOut += 1;
  useUpdatesStore.setState({ busy: true });
  try {
    return await work();
  } finally {
    writesOut -= 1;
    if (writesOut === 0) useUpdatesStore.setState({ busy: false });
  }
};

export const useUpdatesStore = create<UpdatesState>((set, get) => {
  const showError = (title: string, message: string) =>
    useProblemsStore.getState().showError({ title, message });

  const reportUpdate = (error: string) => showError(UPDATE_ERROR_TITLE, error);

  const { landOwn, reload } = standingReads(set, get);

  /** What an action says when the rows it was handed are not ones to act
   *  on: nothing has confirmed them, or a read is about to replace them. */
  const needsCheck = () =>
    showError(UPDATE_ERROR_TITLE, UPDATE_NEEDS_CHECK_NOTE);

  /** What an action says when the rows are fine and the only thing in the
   *  way is the work already running. */
  const oneAtATime = () =>
    showError(UPDATE_ERROR_TITLE, UPDATES_ONE_AT_A_TIME_NOTE);

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
      // cost the network twice for one answer. A write already running is
      // the other half: the fetch builds its report once, so a commit that
      // lands while it is out would not be in it, and landing it would put
      // the rows back as they were before that commit. Every write that
      // goes through [holdingBusy] raises `busy`, so this reads one flag
      // rather than asking each path.
      if (get().checking || get().busy) return;
      set({ checking: true });
      try {
        const response = await settled(commands.updatesRefresh());
        // The fetch reads the standing after fetching every mirror, so it
        // ranks by when it lands — and no write that raises `busy` can have
        // committed behind it, because one out is what refuses this check.
        landOwn(response);
        if (response.status === "error")
          showError(UPDATE_ERROR_TITLE, response.error);
      } finally {
        set({ checking: false });
      }
    },

    updateOne: async (row) => {
      if (rowUnsettled(get(), row)) return needsCheck();
      await holdingBusy(async () => {
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
          // One package's apply, so a removal it reports is that package's.
          sayApply(updatedToastLabel(row.name), answer.data.update, 1);
          applied = true;
        }
        // Whatever it answered, the standing is read again: the work can
        // commit and then fail, and the rows must be what landed.
        await reload();
        if (applied) await rescanEverything();
      });
    },

    updateRows: async (wanted) => {
      const state = get();
      if (wanted.some((row) => rowUnsettled(state, row))) return needsCheck();
      await holdingBusy(async () => {
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
        const what = noRun();
        // Whether anything in this run failed. Every failure reaches the
        // person through `report` — a place that refused, a package its
        // place left out of the answer — so wrapping it is what tells a
        // run that wrote nothing because it could not from one that wrote
        // nothing because there was nothing left to write.
        let failed = false;
        const report = (error: string) => {
          failed = true;
          reportUpdate(error);
        };
        const answer = await caught(writeRows(rows, report, what));
        // A rejection escapes the sequence without touching the record —
        // only this catch saw it, and the places that did commit before it
        // are still in there to be said.
        if (answer.status === "error") report(answer.error);
        await reload();
        // Said off what the applies answered, never off the rows the click
        // covered: a place the plan held back needs attention on its own
        // row, it is not one more updated. Said whether or not a place
        // failed — the error is its own toast, and what the rest of the
        // run did to the person's packages is not the error's to swallow.
        // Counted off the rows that asked, through the one identity rule:
        // two projects' `gh` from unrelated catalogs are two packages.
        sayApply(
          bulkLine(packageCount(what.wrote), failed),
          what,
          packageCount(what.lost),
        );
        await rescanEverything();
      });
    },

    setAutoUpdate: followSwitch({
      set,
      get,
      holding: holdingBusy,
      report: (error) => showError(UPDATE_ERROR_TITLE, error),
    }),

    setIgnored: async (row, ignored) => {
      // The mute captures nothing off the row, so `rowUnsettled` is not what
      // bars it. What bars it is the check: a report built before this
      // commit must not land after it, and refusing here is what keeps the
      // fetch from being out at all.
      if (get().checking || get().busy) return oneAtATime();
      await holdingBusy(async () => {
        const response = await settled(writeIgnored(row, ignored));
        if (response.status === "error")
          showError(UPDATE_ERROR_TITLE, response.error);
        // The command answers with the overview it rebuilt, and this reads
        // it again anyway: the command can persist the preference and then
        // fail building the overview, which only the read answers.
        await reload();
      });
    },
  };
});
