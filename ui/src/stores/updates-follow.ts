// The Follow source switch: one row's state change, then a write that
// settles behind it. The chain a flip starts — move the hold, apply the
// scope, then read every scope's standing again — takes seconds of git and
// planning, and awaiting it before the switch moved held the whole page for
// as long as it ran. The flip is recorded here as pending, worn by the rows
// on screen until the read that follows the write lands, and its scope
// holds while it is outstanding: an apply moves what is installed there,
// and nowhere else.
import {
  commands,
  type ItemKind,
  type Scope,
  type UpdateRow,
} from "@/bindings";
import { UPDATE_NEEDS_CHECK_NOTE } from "@/lib/copy-updates";
import type { ReadState } from "@/lib/read-state";
import { sameScope } from "@/lib/scope";
import { settled } from "@/lib/settled";
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
  report,
}: {
  set: (partial: Partial<Pick<FollowStore, "rows" | "pendingFollows">>) => void;
  get: () => FollowStore;
  report: (error: string) => void;
}) {
  return async (row: UpdateRow, auto: boolean): Promise<void> => {
    // Switching following OFF holds the package at what is installed now.
    // With nothing installed to hold at, there is nothing to switch —
    // never fall through to null, which means "follow" (the opposite).
    const hold = row.current?.commit ?? null;
    if (!auto && hold === null) return;
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
    try {
      const response = await settled(
        commands.packageSetRev(
          row.scope,
          row.kind,
          row.name,
          auto ? null : hold,
        ),
      );
      if (response.status === "error") {
        // Nothing committed, so nothing is coming to replace the rows the
        // flip painted: put the switch back where the click moved it from,
        // and say why now rather than in the seconds a read would take.
        //
        // That is the best answer available, not a certain one. The rows on
        // screen wear the flip, so they cannot say where the engine has the
        // switch, and a read that landed while the write was out is worn
        // over too. What puts it beyond doubt is the next landing, which
        // carries the engine's own answer once no flip is pending.
        set({
          rows: withPending(get().rows, [{ ...flip, pinned: row.pinned }]),
        });
        report(response.error);
        return;
      }
      // Every scope's standing is read again behind the apply. The scan
      // and the audit are not: switching Follow back on resolves the
      // package at its source's tip and moves installed bytes they both
      // answer for, so both are left dated until something else asks.
      // `update-follow.dom.test.tsx` holds that as it is. It is how the
      // flip has always behaved, not something this store changed.
      await get().reload();
    } finally {
      set({
        pendingFollows: get().pendingFollows.filter(
          (one) => one.id !== flip.id,
        ),
      });
    }
  };
}
