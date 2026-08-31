import { toast } from "sonner";
import { create } from "zustand";
import {
  commands,
  type ItemWarning,
  type UpdateRow,
  type UpdatesReport_Serialize,
} from "@/bindings";
import { UPDATE_ERROR_TITLE } from "@/lib/copy";
import {
  nothingToUpdateToastLabel,
  UPDATE_NEEDS_CHECK_NOTE,
} from "@/lib/copy-updates";
import {
  READ_PENDING,
  type ReadState,
  readOf,
  readOrder,
} from "@/lib/read-state";
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
import { applyRow, applyRows } from "./updates-apply";
import {
  followSwitch,
  type PendingFollow,
  withPending,
} from "./updates-follow";

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

  // Reads of the standing overlap: startup against the page's own mount,
  // the focus rescan against both, every mutation re-reading behind them.
  const order = readOrder();

  // The one place a read of the standing lands, however it went. A failure
  // — a returned refusal and a rejected call alike, via `settled` — keeps
  // the rows it had along with the age they had: a check that could not run
  // fetched nothing, so the last fetch is still when these rows were last
  // true, and `read` says they are not confirmed. The rows wear every flip
  // whose write has not answered, so a landing cannot bounce a switch back
  // under the hand that moved it.
  //
  // `ticket` ranks this answer against the other reads out: an older one
  // landing last writes nothing at all, rows and read state alike.
  const land = (
    ticket: number,
    response:
      | { status: "ok"; data: UpdatesReport_Serialize }
      | { status: "error"; error: string },
  ) => {
    if (!order.lands(ticket)) return;
    if (response.status === "ok") {
      set({
        rows: withPending(response.data.rows, get().pendingFollows),
        warnings: response.data.warnings,
        lastFetched: response.data.lastFetched,
        read: readOf(response),
      });
    } else {
      set({ read: readOf(response) });
    }
  };

  /** What a commit-applying action says instead of running. Each captures
   *  values off the rows it was handed, so it may run only against rows a
   *  read confirmed and outside a scope a follow switch is settling in. */
  const needsCheck = () =>
    showError(UPDATE_ERROR_TITLE, UPDATE_NEEDS_CHECK_NOTE);

  const reload = async () => {
    const ticket = order.begin();
    land(ticket, await settled(commands.updatesOverview()));
  };

  return {
    rows: [],
    warnings: [],
    lastFetched: null,
    busy: false,
    checking: false,
    pendingFollows: [],
    read: READ_PENDING,

    reload,

    check: async () => {
      // A check already running answers this click too; a second fetch would
      // cost the network twice for one answer.
      if (get().checking) return;
      set({ checking: true });
      try {
        const response = await settled(commands.updatesRefresh());
        // A fetch reports the state its own work produced, so it ranks by
        // when it lands: no read still out saw anything newer than this.
        land(order.begin(), response);
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
        const answer = await caught(applyRow(row, reportUpdate));
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
        const answer = await caught(applyRows(rows, reportUpdate, outcome));
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
      const response = await settled(
        commands.updateSetIgnored(
          row.scope,
          row.kind,
          row.name,
          row.repo,
          ignored,
        ),
      );
      if (response.status === "ok") {
        // The command answers with the overview it just rebuilt, so it
        // outranks every read begun before this moment.
        land(order.begin(), response);
        return;
      }
      showError(UPDATE_ERROR_TITLE, response.error);
      // It can persist the preference and then fail building the overview,
      // so the rows on screen may no longer be the truth: one read answers
      // either way.
      await reload();
    },
  };
});
