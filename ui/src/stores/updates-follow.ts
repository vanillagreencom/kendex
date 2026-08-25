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
import { sameScope } from "@/lib/scope";
import { settled } from "@/lib/settled";

/** A follow switch moved but not yet answered for: the place it was moved
 *  in, and the position it was moved to. */
export interface PendingFollow {
  /** This flip, apart from any other — what retires the right entry once a
   *  reverting one has been replaced. */
  id: number;
  scope: Scope;
  kind: ItemKind;
  name: string;
  /** True when the switch went off — the package is held at what is
   *  installed now. */
  pinned: boolean;
  /** The write came back refused. The flip stops painting onto landings,
   *  but the rows already wear it, so the entry stays until the read that
   *  replaces them lands: a row must never wear a position the engine did
   *  not take while reporting itself settled. */
  reverting: boolean;
}

let flips = 0;

/** `rows` wearing every pending flip the engine may still take. A read that
 *  began before a flip carries the switch's old position; landing it raw
 *  would bounce the switch back under the hand that moved it. A reverting
 *  flip paints nothing — the landing it is waiting for is the one that puts
 *  the switch back. */
export const withPending = (
  rows: UpdateRow[],
  pending: PendingFollow[],
): UpdateRow[] => {
  const painting = pending.filter((one) => !one.reverting);
  if (painting.length === 0) return rows;
  return rows.map((row) => {
    const flip = painting.find(
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
  /** False when no read has landed since the flip — the rows still wear it
   *  and nothing is coming to replace them. */
  loaded: boolean;
  mutate: (
    work: () => Promise<string | null>,
    kind?: "mutation" | "settle",
  ) => Promise<string | null>;
}

/** The store's `setAutoUpdate`: record the flip, then let the write and the
 *  read that reconciles it settle. Nothing on the click path awaits them —
 *  the rows carry the new position before the first command is sent. */
export function followSwitch({
  set,
  get,
  refuse,
  report,
}: {
  set: (partial: Partial<Pick<FollowStore, "rows" | "pendingFollows">>) => void;
  get: () => FollowStore;
  /** Whether this row's facts are too unsettled to act on, said so. */
  refuse: (row: UpdateRow) => boolean;
  report: (error: string) => void;
}) {
  return async (row: UpdateRow, auto: boolean): Promise<void> => {
    // Switching following OFF holds the package at what is installed now.
    // With nothing installed to hold at, there is nothing to switch —
    // never fall through to null, which means "follow" (the opposite).
    const hold = row.current?.commit ?? null;
    if (!auto && hold === null) return;
    // Same refusal as updateOne: the hold would pin a commit captured from
    // rows an in-flight read is about to replace.
    if (refuse(row)) return;
    flips += 1;
    const flip: PendingFollow = {
      id: flips,
      scope: row.scope,
      kind: row.kind,
      name: row.name,
      pinned: !auto,
      reverting: false,
    };
    const update = (
      change: (pending: PendingFollow[]) => PendingFollow[],
    ): void => set({ pendingFollows: change(get().pendingFollows) });
    const revert = () =>
      update((pending) =>
        pending.map((one) =>
          one.id === flip.id ? { ...one, reverting: true } : one,
        ),
      );
    const retire = () =>
      update((pending) => pending.filter((one) => one.id !== flip.id));
    set({
      rows: withPending(get().rows, [flip]),
      pendingFollows: [...get().pendingFollows, flip],
    });
    let refused = false;
    try {
      const error = await get().mutate(async () => {
        const response = await settled(
          commands.packageSetRev(
            row.scope,
            row.kind,
            row.name,
            auto ? null : hold,
          ),
        );
        if (response.status === "ok") return null;
        // Nothing committed. The rows still wear a position the engine did
        // not take, so the scope goes on holding until the read behind this
        // puts them right — and the refusal is news now, not in the seconds
        // that read takes.
        refused = true;
        revert();
        report(response.error);
        return response.error;
      }, "settle");
      if (error !== null && !refused) report(error);
    } finally {
      // A refusal whose reads all failed leaves the rows as the flip
      // painted them with nothing coming to replace them: put the switch
      // back where the engine still has it before letting the scope go.
      if (refused && !get().loaded) {
        set({
          rows: withPending(get().rows, [
            { ...flip, pinned: row.pinned, reverting: false },
          ]),
        });
      }
      retire();
    }
  };
}
