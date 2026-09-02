// The Follow source switch: one row's state change, then a write that
// settles behind it. The chain a flip starts — move the hold, apply the
// scope, then read every scope's standing again — takes seconds of git and
// planning, and awaiting it before the switch moved left the switch itself
// dead under the hand that clicked it. The flip is recorded here as
// pending, worn by the rows on screen until the read that follows the
// write lands.
//
// Two different things are scoped and page-wide. What the pending record
// decides is which ROWS the landing may not be acted on from — an apply
// moves what is installed in that scope and nowhere else. The write itself
// raises the store's page-wide `busy` for as long as it, its reload and the
// rescan behind it run, because that flag is what a check refuses on, and a
// write it did not cover is a check running beside a commit its report
// predates.
import {
  commands,
  type ItemKind,
  type Scope,
  type UpdateRow,
} from "@/bindings";
import {
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATES_ONE_AT_A_TIME_NOTE,
} from "@/lib/copy-updates";
import type { ReadState } from "@/lib/read-state";
import { rescanEverything } from "@/lib/rescan";
import { sameScope } from "@/lib/scope";
import { settled } from "@/lib/settled";
import { saying } from "@/lib/undone";
import { rowUnsettled } from "@/lib/updates-read-state";

/** A follow switch moved but not yet answered for: the place it was moved
 *  in, and the position it was moved to. */
export interface PendingFollow {
  /** This flip, apart from any other — what retires the right entry when
   *  two are outstanding in different scopes. */
  id: number;
  scope: Scope;
  kind: ItemKind;
  name: string;
  /** True when the switch went off — the package is held at what is
   *  installed now. */
  pinned: boolean;
}

let flips = 0;

/** `rows` wearing every pending flip the engine may still take. A read that
 *  answers while a flip is outstanding carries the switch's old position;
 *  landing it raw would bounce the switch back under the hand that moved
 *  it. */
export const withPending = (
  rows: UpdateRow[],
  pending: PendingFollow[],
): UpdateRow[] => {
  if (pending.length === 0) return rows;
  return rows.map((row) => {
    const flip = pending.find(
      (one) =>
        one.kind === row.kind &&
        one.name === row.name &&
        sameScope(one.scope, row.scope),
    );
    if (!flip) return row;
    // The engine derives one from the other — a row is pinned exactly when
    // something holds it — so painting `pinned` alone would be a shape no
    // overview can return. The owner is always this declaration's own: a
    // hold a source or a parent owns locks the switch, so those rows never
    // accept a flip.
    return {
      ...row,
      pinned: flip.pinned,
      holdOwner: flip.pinned ? { kind: "package" as const } : null,
    };
  });
};

interface FollowStore {
  rows: UpdateRow[];
  pendingFollows: PendingFollow[];
  read: ReadState;
  busy: boolean;
  checking: boolean;
  reading: boolean;
  reload: () => Promise<void>;
}

/** The store's `setAutoUpdate`: record the flip, then let the write and the
 *  read that reconciles it settle. Nothing on the click path awaits them —
 *  the rows carry the new position before the first command is sent. */
export function followSwitch({
  set,
  get,
  holding,
  report,
}: {
  set: (partial: Partial<Pick<FollowStore, "rows" | "pendingFollows">>) => void;
  get: () => FollowStore;
  /** The store's `holdingBusy`, taken as an argument because this module is
   *  the one the store imports. The flip commits like any other write, so
   *  it raises `busy` and a check started beside it is refused. */
  holding: <T>(work: () => Promise<T>) => Promise<T>;
  report: (error: string) => void;
}) {
  return async (row: UpdateRow, auto: boolean): Promise<void> => {
    // Switching following OFF holds the package at what is installed now.
    // With nothing installed to hold at, there is nothing to switch —
    // never fall through to null, which means "follow" (the opposite).
    const hold = row.current?.commit ?? null;
    if (!auto && hold === null) return;
    // One write at a time, page-wide: the flip commits like any other, and
    // asked before the switch moves on screen, so a refusal never leaves a
    // position the engine was never told about.
    if (get().busy) {
      report(UPDATES_ONE_AT_A_TIME_NOTE);
      return;
    }
    // Same refusal as updateOne: the hold would pin a commit captured from
    // rows nothing has confirmed, or from a scope another flip is already
    // applying.
    if (rowUnsettled(get(), row)) {
      report(UPDATE_NEEDS_CHECK_NOTE);
      return;
    }
    flips += 1;
    const flip: PendingFollow = {
      id: flips,
      scope: row.scope,
      kind: row.kind,
      name: row.name,
      pinned: !auto,
    };
    set({
      rows: withPending(get().rows, [flip]),
      pendingFollows: [...get().pendingFollows, flip],
    });
    // The switch has already moved on screen; `busy` covers the write and
    // the read behind it, and holds every control on the page for that
    // long — a commit is a commit, whichever scope it lands in.
    await holding(async () => {
      try {
        // The write says whatever account its answer carries — moving a
        // hold can take a declaring package away with it.
        const response = saying(
          await settled(
            commands.packageSetRev(
              row.scope,
              row.kind,
              row.name,
              auto ? null : hold,
            ),
          ),
        );
        // Say why now rather than in the seconds a read takes.
        if (response.status === "error") report(response.error);
      } finally {
        // Retired before the read, so the rows come back as the engine has
        // them rather than wearing a flip that has already answered.
        set({
          pendingFollows: get().pendingFollows.filter(
            (one) => one.id !== flip.id,
          ),
        });
        // Read again whichever way the write answered. An error is not proof
        // that nothing changed: `package_set_rev` persists the revision
        // through `set_rev_with` and only then runs the apply, so a failed
        // apply returns an error over a manifest that already moved. Putting
        // the switch back from the click's own row would show that as
        // settled and re-open every action against it.
        await get().reload();
        // Then the scan and the audit, which the standing does not cover:
        // the flip runs an apply, and an apply moves the installed bytes
        // the scan lists and the audit scores.
        //
        // Asked whatever the write answered and whichever way the switch
        // went. A refusal is no account of what is on disk — the write
        // runs the leaving packages' uninstallers before the plan
        // (`repo_effects::execute`), and an error over those leaves what
        // they did to the repository standing. Nor is an answer that
        // landed: `moved` covers the two states `moving` counts, `removed`
        // the other destructive one, and a dropped rendering can answer
        // with all three fields empty, so no predicate over the response
        // is complete. A flip that turns out to have written nothing pays
        // what every other write pays — the page held for a machine-wide
        // scan and a forced audit — rather than a page left dated.
        await rescanEverything();
      }
    });
  };
}
