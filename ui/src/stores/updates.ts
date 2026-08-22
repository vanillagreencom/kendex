import { create } from "zustand";
import { commands, type ItemWarning, type UpdateRow } from "@/bindings";
import { UPDATE_ERROR_TITLE } from "@/lib/copy";
import { keepIfSame } from "@/lib/same-read";
import { manifestRewritten } from "./manifest-sync";
import { useProblemsStore } from "./problems";
import { refusesForUnsaved } from "./unsaved-first";
import { applyMany, applyOne } from "./updates-apply";
import { updateTickets } from "./updates-order";

interface UpdatesState {
  rows: UpdateRow[];
  /** Packages whose standing could not be computed — shown, never treated
   *  as current. */
  warnings: ItemWarning[];
  busy: boolean;
  /** True while a mirror fetch is running — the explicit "check". */
  checking: boolean;
  /** True while an ordinary read of the standing is running — the one the
   *  project list starts, and the one every write ends with. Kept apart
   *  from {@link checking}, which gates the buttons that apply a revision:
   *  a background read is no reason to take those away. */
  reading: boolean;
  loaded: boolean;
  /** Why the last read of the standing failed, or null. A load runs on its
   *  own at startup, so it cannot open the error modal a click may — the
   *  screens that read the standing say what happened instead. */
  error: string | null;
  /** Re-read the standing. `afterWrite` marks a read that follows a write
   *  this app just made: it lands whatever polls are in flight, and puts
   *  every older check out of date, because it is reading a file that
   *  moved rather than guessing whether it did. */
  load: (opts?: { afterWrite?: boolean }) => Promise<void>;
  check: () => Promise<void>;
  updateOne: (row: UpdateRow) => Promise<void>;
  /** Bring every updatable place among `rows` current — the page-level
   *  button passes every visible row, a package's button its own places. */
  updateRows: (rows: UpdateRow[]) => Promise<void>;
  setAutoUpdate: (row: UpdateRow, auto: boolean) => Promise<void>;
  setIgnored: (row: UpdateRow, ignored: boolean) => Promise<void>;
}

/** Whether a read of the standing is running at all, of either kind. What
 *  the per-place marks ask, so a place with no row yet reads as being
 *  looked at rather than as one nobody asked about. */
export const updatesReading = (state: {
  checking: boolean;
  reading: boolean;
}): boolean => state.checking || state.reading;

/** Whether the rows on screen may be acted on. A read that failed keeps the
 *  last good rows rather than blanking the page, which is right for reading
 *  — but a button that applies a revision off a row nobody could confirm is
 *  the mark that called a place untouched when nobody had looked. `loaded`
 *  is the read having succeeded; `busy` is one already running; and
 *  `checking` is a fetch of newer versions still in flight. Applying
 *  during that fetch acts on the revision the row had before it — and the
 *  read that follows the write retires the check, so the answer the person
 *  asked for is thrown away to apply the one it was replacing. */
export const canApplyUpdates = (state: {
  loaded: boolean;
  busy: boolean;
  checking: boolean;
}): boolean => state.loaded && !state.busy && !state.checking;

export const useUpdatesStore = create<UpdatesState>((set) => {
  const showError = (title: string, message: string) =>
    useProblemsStore.getState().showError({ title, message });

  const { ticket, fetchEnded } = updateTickets();

  const read = async (newest: () => boolean) => {
    let response: Awaited<ReturnType<typeof commands.updatesOverview>>;
    try {
      response = await commands.updatesOverview();
    } catch (thrown) {
      // A rejected read is a read that failed. Left to reject it would end
      // the pass with nothing said, and every place would read as still
      // being checked with nothing running and no note to say otherwise.
      if (newest()) set({ loaded: false, error: String(thrown) });
      return;
    }
    if (!newest()) return;
    // A failed reload marks the data stale (loaded = false) rather than
    // leaving the last-good rows trusted — the package page gates the
    // Update button on `loaded`, and acting on rows we could not refresh
    // is exactly the fail-open this closes.
    if (response.status === "ok")
      set((state) => ({
        // A re-read that changed nothing hands back what is already on
        // screen: every screen joining on these rows memoizes on identity.
        rows: keepIfSame(state.rows, response.data.rows),
        warnings: keepIfSame(state.warnings, response.data.warnings),
        loaded: true,
        error: null,
      }));
    else set({ loaded: false, error: response.error });
  };

  // How many ordinary reads are running, so the flag comes down when the
  // last one lands rather than the first.
  let running = 0;
  const reload = async (afterWrite = false) => {
    const newest = ticket(false, afterWrite);
    running += 1;
    set({ reading: true });
    try {
      await read(newest);
    } finally {
      running -= 1;
      if (running === 0) set({ reading: false });
    }
  };

  return {
    rows: [],
    warnings: [],
    busy: false,
    checking: false,
    reading: false,
    loaded: false,
    error: null,

    load: async (opts) => {
      await reload(opts?.afterWrite === true);
    },

    check: async () => {
      set({ checking: true });
      const newest = ticket(true);
      try {
        let response: Awaited<ReturnType<typeof commands.updatesRefresh>>;
        try {
          response = await commands.updatesRefresh();
        } catch (thrown) {
          // A rejected read is a read that failed. Left to reject, the
          // standing keeps its last successful values and the marks go on
          // presenting stale rows as a check that worked.
          if (newest()) {
            set({ loaded: false, error: String(thrown) });
            showError(UPDATE_ERROR_TITLE, String(thrown));
          }
          return;
        }
        if (!newest()) return;
        if (response.status === "ok") {
          set({
            rows: response.data.rows,
            warnings: response.data.warnings,
            loaded: true,
            error: null,
          });
        } else {
          set({ loaded: false, error: response.error });
          showError(UPDATE_ERROR_TITLE, response.error);
        }
      } finally {
        set({ checking: fetchEnded() });
      }
    },

    updateOne: applyOne,

    updateRows: applyMany,

    setAutoUpdate: async (row, auto) => {
      // Switching following OFF holds the package at what is installed now.
      // With nothing installed to hold at, there is nothing to switch —
      // never fall through to null, which means "follow" (the opposite).
      const hold = row.current?.commit ?? null;
      if (!auto && hold === null) return;
      // Before the flag goes up: a refusal after it would leave every
      // control on the page waiting on work that never started.
      if (refusesForUnsaved(row.scope)) return;
      set({ busy: true });
      try {
        const response = await commands.packageSetRev(
          row.scope,
          row.kind,
          row.name,
          auto ? null : hold,
        );
        const wrote = response.status !== "error";
        if (wrote) {
          // Holding a package at a version, or letting it follow again,
          // writes that place's kendex.toml — before the tables re-read,
          // or a save of the copy the Customize tab holds puts the old
          // file back over what this just recorded.
          await manifestRewritten(row.scope);
        } else showError(UPDATE_ERROR_TITLE, response.error);
        // Only a write earns the rank that retires a check already in
        // flight; a refusal moved nothing, so this is an ordinary poll.
        await reload(wrote);
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
          error: null,
        });
      else showError(UPDATE_ERROR_TITLE, response.error);
    },
  };
});
