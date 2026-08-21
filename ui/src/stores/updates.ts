import { toast } from "sonner";
import { create } from "zustand";
import { commands, type ItemWarning, type UpdateRow } from "@/bindings";
import { UPDATE_ERROR_TITLE, updatedToastLabel } from "@/lib/copy";
import {
  nothingToUpdateToastLabel,
  updatedWithPlaceToastLabel,
} from "@/lib/copy-updates";
import { scopeKey } from "@/lib/scope";
import {
  packageCount,
  placeName,
  skippedPlaces,
  updatablePlaces,
} from "@/lib/update-groups";
import { bulkUpdateToast } from "@/lib/update-toasts";
import { useAuditStore } from "./audit";
import { useProblemsStore } from "./problems";
import { useScanStore } from "./scan";

/** A row worth a line on the page: a newer version, a package gone from
 *  its source, or installs disagreeing on their version — each a standing
 *  fact someone can act on. */
const noteworthy = (row: UpdateRow): boolean =>
  row.updateAvailable || row.removedUpstream || row.mixed;

/** The sidebar badge's number: packages with news someone would want to
 *  hear, counted once however many places they are installed in. Ignored
 *  ones asked not to be counted; held ones still count — a hold is "not
 *  yet", not "never tell me". */
export const visibleUpdateCount = (rows: UpdateRow[]): number =>
  packageCount(visibleUpdates(rows));

/** The Updates page's main list: everything noteworthy that has not been
 *  muted. */
export const visibleUpdates = (rows: UpdateRow[]): UpdateRow[] =>
  rows.filter((row) => noteworthy(row) && !row.ignored);

/** The collapsed "hidden updates" section: muted packages whose news is
 *  still real — with the way back out. */
export const hiddenUpdates = (rows: UpdateRow[]): UpdateRow[] =>
  rows.filter((row) => noteworthy(row) && row.ignored);

interface UpdatesState {
  rows: UpdateRow[];
  /** Packages whose standing could not be computed — shown, never treated
   *  as current. */
  warnings: ItemWarning[];
  busy: boolean;
  /** True while a mirror fetch is running — the explicit "check". */
  checking: boolean;
  loaded: boolean;
  load: () => Promise<void>;
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

  const apply = async (row: UpdateRow): Promise<boolean> => {
    // Held packages move by moving the hold; following ones come current
    // by applying the scope — which is what following means, and brings
    // any other pending changes in that scope along.
    const response =
      row.pinned && row.latest
        ? await commands.packageSetRev(
            row.scope,
            row.kind,
            row.name,
            row.latest.commit,
          )
        : await commands.applyPlan(row.scope, false, []);
    if (response.status === "error") {
      showError(UPDATE_ERROR_TITLE, response.error);
      return false;
    }
    return true;
  };

  const reload = async () => {
    const response = await commands.updatesOverview();
    // A failed reload marks the data stale (loaded = false) rather than
    // leaving the last-good rows trusted — the package page gates the
    // Update button on `loaded`, and acting on rows we could not refresh
    // is exactly the fail-open this closes.
    if (response.status === "ok")
      set({
        rows: response.data.rows,
        warnings: response.data.warnings,
        loaded: true,
      });
    else set({ loaded: false });
  };

  return {
    rows: [],
    warnings: [],
    busy: false,
    checking: false,
    loaded: false,

    load: async () => {
      await reload();
    },

    check: async () => {
      set({ checking: true });
      try {
        const response = await commands.updatesRefresh();
        if (response.status === "ok") {
          set({
            rows: response.data.rows,
            warnings: response.data.warnings,
            loaded: true,
          });
        } else {
          set({ loaded: false });
          showError(UPDATE_ERROR_TITLE, response.error);
        }
      } finally {
        set({ checking: false });
      }
    },

    updateOne: async (row) => {
      set({ busy: true });
      try {
        if (await apply(row)) {
          // A follower comes current by applying its scope, which brings
          // that scope's other followers along — the toast says so rather
          // than letting the extra changes look like a surprise.
          toast.success(
            row.pinned
              ? updatedToastLabel(row.name)
              : updatedWithPlaceToastLabel(row.name, placeName(row.scope)),
          );
          await reload();
          await useScanStore.getState().refresh();
          await useAuditStore.getState().refresh({ force: true });
        }
      } finally {
        set({ busy: false });
      }
    },

    updateRows: async (wanted) => {
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
        // Move every hold first — each move applies its whole scope, so
        // that scope's followers are already current — then one apply per
        // scope no hold touched. Never two applies for one scope.
        let ok = true;
        const applied = new Set<string>();
        for (const row of rows.filter((row) => row.pinned)) {
          if (await apply(row)) applied.add(scopeKey(row.scope));
          else ok = false;
        }
        const scopes = new Map(
          rows
            .filter((row) => !row.pinned && !applied.has(scopeKey(row.scope)))
            .map((row) => [scopeKey(row.scope), row] as const),
        );
        for (const row of scopes.values()) {
          const response = await commands.applyPlan(row.scope, false, []);
          if (response.status === "error") {
            showError(UPDATE_ERROR_TITLE, response.error);
            ok = false;
          }
        }
        await reload();
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
      set({ busy: true });
      try {
        const response = await commands.packageSetRev(
          row.scope,
          row.kind,
          row.name,
          auto ? null : hold,
        );
        if (response.status === "error") {
          showError(UPDATE_ERROR_TITLE, response.error);
        }
        await reload();
      } finally {
        set({ busy: false });
      }
    },

    setIgnored: async (row, ignored) => {
      const response = await commands.updateSetIgnored(
        row.scope,
        row.kind,
        row.name,
        row.repo,
        ignored,
      );
      if (response.status === "ok")
        set({
          rows: response.data.rows,
          warnings: response.data.warnings,
          loaded: true,
        });
      else showError(UPDATE_ERROR_TITLE, response.error);
    },
  };
});
