import { toast } from "sonner";
import { create } from "zustand";
import { commands, type ItemWarning, type UpdateRow } from "@/bindings";
import { UPDATE_ERROR_TITLE, updatedToastLabel } from "@/lib/copy";
import {
  nothingToUpdateToastLabel,
  UPDATE_NEEDS_CHECK_NOTE,
  updatedWithPlaceToastLabel,
} from "@/lib/copy-updates";
import {
  placeName,
  skippedPlaces,
  updatablePlaces,
  visibleUpdates,
} from "@/lib/update-groups";
import { bulkUpdateToast } from "@/lib/update-toasts";
import { useAuditStore } from "./audit";
import { useProblemsStore } from "./problems";
import { useScanStore } from "./scan";
import { applyRow, applyRows } from "./updates-apply";
import { overviewApplier } from "./updates-overview";

interface UpdatesState {
  rows: UpdateRow[];
  /** Packages whose standing could not be computed — shown, never treated
   *  as current. */
  warnings: ItemWarning[];
  busy: boolean;
  /** True while a mirror fetch is running — the explicit "check". */
  checking: boolean;
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
  mutate: (work: () => Promise<string | null>) => Promise<string | null>;
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

  const applyOverview = overviewApplier(set);

  const reload = async () => {
    await applyOverview(() => commands.updatesOverview());
  };

  return {
    rows: [],
    warnings: [],
    busy: false,
    checking: false,
    loaded: false,
    error: null,

    load: async () => {
      await reload();
    },

    mutate: async (work) => {
      // The applier's own error matters too: work() rejecting in transport
      // never assigns failure, and only the applier saw the rejection —
      // dropping it would let callers toast success over an IPC failure.
      let failure: string | null = null;
      const applierError = await applyOverview(async () => {
        failure = await work();
        return commands.updatesOverview();
      }, "mutation");
      return failure ?? applierError;
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
      // A check in flight is about to replace these rows: an update
      // queued now would apply the latest captured before it — refuse
      // rather than commit stale arguments after fresher rows land.
      if (get().checking) {
        showError(UPDATE_ERROR_TITLE, UPDATE_NEEDS_CHECK_NOTE);
        return;
      }
      set({ busy: true });
      try {
        // The commit and its follow-up overview ride the side-effect
        // chain, so nothing older can land on top of them.
        let applied = false;
        const error = await get().mutate(async () => {
          applied = await applyRow(row, reportUpdate);
          return null;
        });
        if (error !== null) {
          showError(UPDATE_ERROR_TITLE, error);
        } else if (applied) {
          // A follower comes current by applying its scope, which brings
          // that scope's other followers along — the toast says so rather
          // than letting the extra changes look like a surprise.
          toast.success(
            row.pinned
              ? updatedToastLabel(row.name)
              : updatedWithPlaceToastLabel(row.name, placeName(row.scope)),
          );
          await useScanStore.getState().refresh();
          await useAuditStore.getState().refresh({ force: true });
        }
      } finally {
        set({ busy: false });
      }
    },

    updateRows: async (wanted) => {
      // Same mid-check refusal as updateOne: these rows are about to be
      // replaced, and the holds among them would move to captured commits.
      if (get().checking) {
        showError(UPDATE_ERROR_TITLE, UPDATE_NEEDS_CHECK_NOTE);
        return;
      }
      set({ busy: true });
      try {
        // Edited packages are held by the engine and cannot be updated
        // this way — they need the fork decision first, so they are left
        // out rather than silently surviving the click. Rows that are news
        // without an update (gone upstream, mixed installs) have nothing
        // for this button to do.
        const rows = updatablePlaces(wanted);
        const skipped = skippedPlaces(wanted).length;
        if (rows.length === 0) {
          toast.info(nothingToUpdateToastLabel(skipped));
          return;
        }
        // The whole sequence and its follow-up overview ride the
        // side-effect chain, so nothing older can land on top of them.
        let ok = true;
        const error = await get().mutate(async () => {
          ok = await applyRows(rows, reportUpdate);
          return null;
        });
        // A rejection escapes the sequence without touching ok — only the
        // applier saw it, and success must not be claimed over it.
        if (error !== null) {
          showError(UPDATE_ERROR_TITLE, error);
          ok = false;
        }
        if (ok)
          toast.success(
            bulkUpdateToast(rows, skipped, visibleUpdates(get().rows)),
          );
        await useScanStore.getState().refresh();
        await useAuditStore.getState().refresh({ force: true });
      } finally {
        set({ busy: false });
      }
    },

    setAutoUpdate: async (row, auto) => {
      // Switching following OFF holds the package at what is installed now.
      // With nothing installed to hold at, there is nothing to switch —
      // never fall through to null, which means "follow" (the opposite).
      const hold = row.current?.commit ?? null;
      if (!auto && hold === null) return;
      // Mid-check refusal: the hold would pin a commit captured from rows
      // a running check is about to replace.
      if (get().checking) {
        showError(UPDATE_ERROR_TITLE, UPDATE_NEEDS_CHECK_NOTE);
        return;
      }
      set({ busy: true });
      try {
        const error = await get().mutate(async () => {
          const response = await commands.packageSetRev(
            row.scope,
            row.kind,
            row.name,
            auto ? null : hold,
          );
          return response.status === "error" ? response.error : null;
        });
        if (error !== null) showError(UPDATE_ERROR_TITLE, error);
      } finally {
        set({ busy: false });
      }
    },

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
