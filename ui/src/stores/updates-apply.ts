import { toast } from "sonner";
import { commands, type UpdateRow } from "@/bindings";
import { UPDATE_ERROR_TITLE, updatedToastLabel } from "@/lib/copy";
import {
  nothingToUpdateToastLabel,
  updatedWithPlaceToastLabel,
} from "@/lib/copy-updates";
import { scopeKey } from "@/lib/scope";
import { placeName, skippedPlaces, updatablePlaces } from "@/lib/update-groups";
import { visibleUpdates } from "@/lib/update-rows";
import { bulkUpdateToast } from "@/lib/update-toasts";
import { useAuditStore } from "./audit";
import { manifestRewritten } from "./manifest-sync";
import { useProblemsStore } from "./problems";
import { useScanStore } from "./scan";
import { refusesForUnsaved, refusesForUnsavedIn } from "./unsaved-first";
import { useUpdatesStore } from "./updates";

// Bringing places current, under the updates store's busy flag so every
// control on the page waits on the same one.

const showError = (title: string, message: string) =>
  useProblemsStore.getState().showError({ title, message });

const set = (partial: { busy: boolean }) => useUpdatesStore.setState(partial);
// A read that follows a write outranks one that was only polling, so it is
// never put back by a check that was already on its way. That ranking is
// earned by the write: claimed where nothing moved, it would throw away a
// check the person started and leave the pre-check tables on screen.
const reload = (wrote: boolean) =>
  useUpdatesStore.getState().load(wrote ? { afterWrite: true } : undefined);

const apply = async (row: UpdateRow): Promise<boolean> => {
  // Both branches below rewrite this place's kendex.toml, so unsaved
  // customization for it refuses them — the guard every writer of that
  // file asks, wherever the typing is waiting.
  if (refusesForUnsaved(row.scope)) return false;
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
  // Both branches rewrite this scope's kendex.toml — moving a hold writes
  // the revision, applying writes whatever the plan settled.
  await manifestRewritten(row.scope);
  return true;
};

/** Bring one place current. */
export const applyOne = async (row: UpdateRow): Promise<void> => {
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
      await reload(true);
      await useScanStore.getState().refresh();
      await useAuditStore.getState().refresh({ force: true });
    }
  } finally {
    set({ busy: false });
  }
};

/** Bring every updatable place among `rows` current. */
export const applyMany = async (wanted: UpdateRow[]): Promise<void> => {
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
    // What every way out of here owes: the tables re-read, the success
    // named only if nothing stopped, and the rest of the app told. An exit
    // that skipped it would leave the page showing the world as it was
    // before the button was pressed.
    const finish = async (succeeded: boolean, wrote: boolean) => {
      await reload(wrote);
      if (succeeded)
        toast.success(
          bulkUpdateToast(
            rows,
            skipped,
            visibleUpdates(useUpdatesStore.getState().rows),
          ),
        );
      await useScanStore.getState().refresh();
      await useAuditStore.getState().refresh({ force: true });
    };
    // Every place this touches is asked before the first one is written.
    // Asked per row inside the loops below, the first refusal would leave
    // the set half updated — some places current, one untouched, from a
    // single Update all that never offered to do part of it.
    if (refusesForUnsavedIn(rows.map((row) => row.scope))) return;
    // Move every hold first — each move applies its whole scope, so
    // that scope's followers are already current — then one apply per
    // scope no hold touched. Never two applies for one scope.
    let ok = true;
    const applied = new Set<string>();
    for (const row of rows.filter((row) => row.pinned)) {
      if (await apply(row)) {
        applied.add(scopeKey(row.scope));
        continue;
      }
      // Stop rather than carry on to the next place. The preflight above
      // answered for the set as it stood when the button was pressed; a
      // refusal here is typing that arrived while this was running, and
      // writing the rest over it would be the same loss one place along.
      ok = false;
      break;
    }
    // Whatever stopped the loop above stops this one too: a failure or a
    // refusal there is a reason not to write anywhere else either.
    if (!ok) {
      // Awaited, not returned: `return finish(...)` hands back the promise
      // and lets the `finally` below clear busy while the re-reads are
      // still running, so the controls come back before the tables do and
      // the next thing pressed races this one's scan.
      //
      // The first place refusing is the ordinary way this stops, and then
      // nothing moved: the re-read is a poll like any other, and a check
      // the person started meanwhile outranks it.
      await finish(false, applied.size > 0);
      return;
    }
    // How many scopes this loop actually wrote, so a run that refused at its
    // first place claims nothing over a check already in flight.
    let wrote = 0;
    const scopes = new Map(
      rows
        .filter((row) => !row.pinned && !applied.has(scopeKey(row.scope)))
        .map((row) => [scopeKey(row.scope), row] as const),
    );
    for (const row of scopes.values()) {
      // Asked again, immediately before this write. The preflight spoke for
      // the set at the moment of the click, and every await since has been
      // a window someone could have typed in — this loop reaches the
      // command directly rather than through `apply`, so it owes the
      // question itself.
      if (refusesForUnsaved(row.scope)) {
        ok = false;
        break;
      }
      const response = await commands.applyPlan(row.scope, false, []);
      if (response.status === "error") {
        showError(UPDATE_ERROR_TITLE, response.error);
        ok = false;
        break;
      }
      await manifestRewritten(row.scope);
      wrote += 1;
    }
    await finish(ok, applied.size + wrote > 0);
  } finally {
    set({ busy: false });
  }
};
