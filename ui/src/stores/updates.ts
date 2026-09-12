import { toast } from "sonner";
import { create } from "zustand";
import { commands, type UpdateRow } from "@/bindings";
import {
  repairedToastLabel,
  UPDATE_ERROR_TITLE,
  updatedToastLabel,
} from "@/lib/copy";
import {
  nothingToUpdateToastLabel,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATES_ONE_AT_A_TIME_NOTE,
} from "@/lib/copy-updates";
import { countingWrites } from "@/lib/package-places";
import { READ_PENDING } from "@/lib/read-state";
import { beforeWriting, offerToCommit, rescanEverything } from "@/lib/rescan";
import { caught, settled } from "@/lib/settled";
import { saying } from "@/lib/undone";
import {
  packageCount,
  skippedPlaces,
  updatablePlaces,
} from "@/lib/update-groups";
import { readUnsettled } from "@/lib/updates-read-state";
import { useProblemsStore } from "./problems";
import {
  type ApplyOutcome,
  applyRow,
  applyRows,
  bulkLine,
  noRun,
  repairRow,
  sayApply,
} from "./updates-apply";
import { type Standing, standingReads } from "./updates-standing";

interface UpdatesState extends Standing {
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
  /** How many writes have landed in each place, keyed by
   *  `package-places.ts` [`placeKey`]. A page about one of them keys its own
   *  reads on this beside the installed commit: a write that commits and then
   *  cannot be read back leaves that commit where it was, and the files under
   *  it have changed all the same. Counted per place, so a write to another
   *  package refetches nothing here. */
  writes: Record<string, number>;
  /** Read the standing again and land whatever it answers. Every operation
   *  that commits a change calls it once its own work is done, so the rows
   *  on screen are what actually committed. */
  reload: () => Promise<void>;
  check: () => Promise<void>;
  /** Bring one place current — the package page's Projects tab, which acts
   *  on one copy at a time. Not the Updates page's: every confirm its
   *  review takes goes through [`updateRows`], one place included, so that
   *  page has one applier at every scope it offers. */
  updateOne: (row: UpdateRow) => Promise<void>;
  /** Put a recorded file back at the revision installed in one place —
   *  the package page's missing-files notice. The same single-package
   *  apply, holding every declaration as it is: a held place keeps its
   *  hold, where [`updateOne`] moves it to the newest. The machine is read
   *  again before the rows, because the page that offered the repair may
   *  stand on the row's word alone: with the copy gone the scan holds no
   *  installation there, and rows cleared first would leave it a page
   *  about nowhere for the length of the scan, which sends the reader
   *  back. */
  repairOne: (row: UpdateRow) => Promise<void>;
  /** Bring every updatable place among `rows` current — every scope the
   *  Updates page's review offers, from one place to all of them, and a
   *  place's card. */
  updateRows: (rows: UpdateRow[]) => Promise<void>;
  setIgnored: (row: UpdateRow, ignored: boolean) => Promise<void>;
}

/** Hold the store's `busy` for as long as `work` runs — every write the
 *  exclusion covers, wherever it lives. Paths outside this module reach it
 *  by import. A flag rather than a count: every caller refuses while it is
 *  already up, so this `finally` drops it under nobody. */
export const holdingBusy = async <T>(work: () => Promise<T>): Promise<T> => {
  useUpdatesStore.setState({ busy: true });
  try {
    return await work();
  } finally {
    useUpdatesStore.setState({ busy: false });
  }
};

export const useUpdatesStore = create<UpdatesState>((set, get) => {
  const showError = (title: string, message: string) =>
    useProblemsStore.getState().showError({ title, message });

  const reportUpdate = (error: string) => showError(UPDATE_ERROR_TITLE, error);

  const { landOwn, reload } = standingReads(set);

  const wrote = (rows: UpdateRow[]) =>
    set({ writes: countingWrites(get().writes, rows) });

  /** What an action says when the rows it was handed are not ones to act
   *  on: nothing has confirmed them, or a read is about to replace them. */
  const needsCheck = () =>
    showError(UPDATE_ERROR_TITLE, UPDATE_NEEDS_CHECK_NOTE);

  /** What an action says when the rows are fine and the only thing in the
   *  way is the work already running. */
  const oneAtATime = () =>
    showError(UPDATE_ERROR_TITLE, UPDATES_ONE_AT_A_TIME_NOTE);

  /** One place's write, whichever command runs it: the exclusion, the
   *  commit offer, and the readback around `apply`. `done` is what the
   *  toast says once the apply committed, and `readBack` the two reads
   *  in the order this write needs them. */
  const writeOne = async (
    row: UpdateRow,
    apply: (
      row: UpdateRow,
      report: (error: string) => void,
    ) => Promise<ApplyOutcome>,
    done: string,
    readBack: () => Promise<void>,
  ) => {
    // One write at a time, page-wide: the second committing after the
    // first released `busy` is a check opening over a commit it cannot see.
    if (get().busy) return oneAtATime();
    if (readUnsettled(get())) return needsCheck();
    await holdingBusy(async () => {
      // Before the write: the offer at the end is about what this write
      // did, and that is a comparison against how the projects stood
      // before it.
      const roots = await beforeWriting();
      const answer = await caught(apply(row, reportUpdate));
      if (answer.status === "error") {
        // A transport failure rejects rather than refusing, and only
        // this catch sees it: unreported it would read as a write that
        // landed.
        reportUpdate(answer.error);
      } else if (answer.data.ok) {
        // Either command can come back held: the plan refuses to write
        // over a copy somebody changed, and saying "Updated" over that
        // is the whole point of asking the command what it did.
        // One package's apply, so a removal it reports is that package's.
        sayApply(done, answer.data.update, 1);
      }
      // Whatever it answered, both standings are read again: the work can
      // commit and then fail, and the rows must be what landed. The row
      // this run sent, answered ok or not — `countingWrites` says why an
      // error is not proof that nothing changed. The machine is asked on
      // `rescan.ts`'s rule: whatever the apply answered, and inside the
      // busy the write holds.
      wrote([row]);
      await readBack();
      void offerToCommit(roots);
    });
  };

  return {
    rows: [],
    warnings: [],
    unreadable: [],
    lastFetched: null,
    busy: false,
    checking: false,
    reading: false,
    read: READ_PENDING,
    writes: {},

    reload,

    check: async () => {
      // A check already running answers this click too. A write is the
      // other half: the fetch builds its report once, so a commit landing
      // while it is out would not be in it, and landing that report would
      // put the rows back as they were before the commit.
      if (get().checking || get().busy) return;
      set({ checking: true });
      try {
        const response = await settled(commands.updatesRefresh());
        // The fetch reads the standing after fetching every mirror, so it
        // ranks by when it lands — and one write out is what refused it.
        landOwn(response);
        if (response.status === "error")
          showError(UPDATE_ERROR_TITLE, response.error);
      } finally {
        set({ checking: false });
      }
    },

    updateOne: (row) =>
      writeOne(row, applyRow, updatedToastLabel(row.name), async () => {
        await reload();
        await rescanEverything();
      }),

    repairOne: (row) =>
      writeOne(row, repairRow, repairedToastLabel(row.name), async () => {
        // The machine first, so the page never stands between rows that
        // say nothing is missing and a scan that still sees no copy.
        await rescanEverything();
        await reload();
      }),

    updateRows: async (wanted) => {
      const state = get();
      if (state.busy) return oneAtATime();
      if (readUnsettled(state)) return needsCheck();
      await holdingBusy(async () => {
        // Before the writes, for the reason `updateOne` states.
        const roots = await beforeWriting();
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
        const answer = await caught(applyRows(rows, report, what));
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
        // The rows this run sent, on the same rule: `what.wrote` is what the
        // plan moved, which is the wrong question for a refresh.
        wrote(rows);
        await rescanEverything();
        void offerToCommit(roots);
      });
    },

    setIgnored: async (row, ignored) => {
      // The mute captures nothing off the row, so `readUnsettled` is not
      // what bars it. What bars it is the work already out: a report built
      // before this commit must not land after it.
      if (get().checking || get().busy) return oneAtATime();
      await holdingBusy(async () => {
        // `saying` because a mute that took a declaring package away ran
        // its uninstaller in somebody's repository.
        const { scope, kind, name, repo } = row;
        const response = saying(
          await settled(
            commands.updateSetIgnored(scope, kind, name, repo, ignored),
          ),
        );
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
