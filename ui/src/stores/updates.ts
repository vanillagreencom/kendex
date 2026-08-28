import { toast } from "sonner";
import { create } from "zustand";
import { commands, type ItemWarning, type UpdateRow } from "@/bindings";
import { UPDATE_ERROR_TITLE, updatedToastLabel } from "@/lib/copy";
import {
  nothingToUpdateToastLabel,
  UPDATE_NEEDS_CHECK_NOTE,
} from "@/lib/copy-updates";
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
import { rowUnsettled, unsettled } from "@/lib/updates-read-state";
import { useAuditStore } from "./audit";
import { useProblemsStore } from "./problems";
import { useScanStore } from "./scan";
import { type ApplyOutcome, applyRow, applyRows } from "./updates-apply";
import { followSwitch, type PendingFollow } from "./updates-follow";
import { overviewApplier } from "./updates-overview";

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
  /** True while a plain load, a check, or a mutation is in flight: those
   *  replace every row on screen, so no commit-applying action anywhere
   *  may trust them. A settling follow flip is overview-producing too and
   *  deliberately leaves this down — the apply behind it reaches only its
   *  own scope, so `pendingFollows` holds that scope's rows and the rest
   *  of the page stays live. Read `rowUnsettled`, not this field, to ask
   *  whether one row may be acted on. */
  overviewInFlight: boolean;
  /** Follow switches already moved on screen whose write has not answered.
   *  Their scopes hold; every other row stays live. */
  pendingFollows: PendingFollow[];
  loaded: boolean;
  /** Why the last read of the standing failed, or null. A load runs on its
   *  own at startup, so a failure here is a state for Home and the badge to
   *  show — silence would read as "nothing to update". */
  error: string | null;
  load: () => Promise<void>;
  check: () => Promise<void>;
  /** Run backend-mutating work on the same chain as every other side
   *  effect, landing a fresh overview after it — so operations land in
   *  commit order and none of their answers can shadow a newer one.
   *  Returns the work's own error, or null; the overview that follows
   *  reflects whatever actually committed either way. */
  mutate: (
    work: () => Promise<string | null>,
    kind?: "mutation" | "settle",
  ) => Promise<string | null>;
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

  const applyOverview = overviewApplier(set, () => get().pendingFollows);

  // One predicate for every commit-applying action: the captured row
  // arguments are trustworthy only when the rows are a confirmed current
  // answer and nothing that could replace them is in flight — a failed
  // read, a running check, and a focus-triggered load are all the same
  // reason to wait, and so is a follow switch still settling in the scope
  // the action would apply. Returns whether it was refused, reporting it.
  const refuseUnsettled = (rows: UpdateRow[]): boolean => {
    const state = get();
    if (!unsettled(state) && !rows.some((row) => rowUnsettled(state, row)))
      return false;
    showError(UPDATE_ERROR_TITLE, UPDATE_NEEDS_CHECK_NOTE);
    return true;
  };

  const reload = async () => {
    await applyOverview(() => commands.updatesOverview());
  };

  return {
    rows: [],
    warnings: [],
    lastFetched: null,
    busy: false,
    checking: false,
    overviewInFlight: false,
    pendingFollows: [],
    loaded: false,
    error: null,

    load: async () => {
      await reload();
    },

    mutate: async (work, kind = "mutation") => {
      // The work's failure and the applier's are different news. work()
      // rejecting in transport never assigns failure and only the applier
      // saw it — but once work has answered, the applier's error is the
      // follow-up read's, already told through the store (stale marking,
      // or cleared by a landed reconcile), and returning it would report
      // a committed change as failed — suppressing the caller's success
      // toast and its scan/audit refreshes.
      let failure: string | null = null;
      let answered = false;
      const applierError = await applyOverview(async () => {
        failure = await work();
        answered = true;
        return commands.updatesOverview();
      }, kind);
      if (failure !== null) return failure;
      return answered ? null : applierError;
    },

    check: async () => {
      // A check already running answers this click too; a second in flight
      // would land last-write-wins and could overwrite the fresh answer
      // with a staler one.
      if (get().checking) return;
      set({ checking: true });
      try {
        const error = await applyOverview(
          () => commands.updatesRefresh(),
          "refresh",
        );
        if (error !== null) showError(UPDATE_ERROR_TITLE, error);
      } finally {
        set({ checking: false });
      }
    },

    updateOne: async (row) => {
      // Anything overview-producing in flight is about to replace these
      // rows: an update accepted now would apply the latest captured
      // before it — refuse rather than commit stale arguments after
      // fresher rows land.
      if (refuseUnsettled([row])) return;
      set({ busy: true });
      try {
        // The commit and its follow-up overview ride the side-effect
        // chain, so nothing older can land on top of them.
        let outcome: ApplyOutcome = { ok: false, update: null };
        const error = await get().mutate(async () => {
          outcome = await applyRow(row, reportUpdate);
          return null;
        });
        if (error !== null) {
          showError(UPDATE_ERROR_TITLE, error);
        } else if (outcome.ok) {
          // A following package can come back held: the plan refuses to
          // write over a copy somebody changed, and saying "Updated" over
          // that is the whole point of asking the command what it did.
          if (outcome.update) showUpdateOutcome(row.name, outcome.update);
          else toast.success(updatedToastLabel(row.name));
          await useScanStore.getState().refresh();
          await useAuditStore.getState().refresh({ force: true });
        }
      } finally {
        set({ busy: false });
      }
    },

    updateRows: async (wanted) => {
      // Same refusal as updateOne: the holds among these rows would move
      // to captured commits.
      if (refuseUnsettled(wanted)) return;
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
        // The whole sequence and its follow-up overview ride the
        // side-effect chain, so nothing older can land on top of them.
        const outcome = startBulk(skipped);
        const error = await get().mutate(async () => {
          await applyRows(rows, reportUpdate, outcome);
          return null;
        });
        // A rejection escapes the sequence without touching the outcome —
        // only the applier saw it, and success must not be claimed over it.
        if (error !== null) {
          showError(UPDATE_ERROR_TITLE, error);
          outcome.ok = false;
        }
        // Counted off what the applies reported, never off the rows the
        // click covered: a place the plan held back needs attention on its
        // own row, it is not one more updated.
        // Said whether or not a place failed: the error is its own toast,
        // and what the rest of the run did to the person's packages is not
        // the error's to swallow.
        showBulkOutcome(outcome, visibleUpdates(get().rows));
        await useScanStore.getState().refresh();
        await useAuditStore.getState().refresh({ force: true });
      } finally {
        set({ busy: false });
      }
    },

    setAutoUpdate: followSwitch({
      set,
      get,
      refuse: (row) => refuseUnsettled([row]),
      report: (error) => showError(UPDATE_ERROR_TITLE, error),
    }),

    setIgnored: async (row, ignored) => {
      const error = await applyOverview(
        () =>
          commands.updateSetIgnored(
            row.scope,
            row.kind,
            row.name,
            row.repo,
            ignored,
          ),
        "mutation",
      );
      if (error !== null) showError(UPDATE_ERROR_TITLE, error);
    },
  };
});
