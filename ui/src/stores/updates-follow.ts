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
  scope: Scope;
  kind: ItemKind;
  name: string;
  /** True when the switch went off — the package is held at what is
   *  installed now. */
  pinned: boolean;
}

/** `rows` wearing every pending flip. A read that began before a flip
 *  carries the switch's old position; landing it raw would bounce the
 *  switch back under the hand that moved it. */
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
    // A hold the source or a parent owns is not this switch's to move —
    // those rows never accept a flip, so a pending one is always this
    // declaration's own.
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
    const pending: PendingFollow = {
      scope: row.scope,
      kind: row.kind,
      name: row.name,
      pinned: !auto,
    };
    const retire = () =>
      set({
        pendingFollows: get().pendingFollows.filter((one) => one !== pending),
      });
    set({
      rows: withPending(get().rows, [pending]),
      pendingFollows: [...get().pendingFollows, pending],
    });
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
        // Nothing committed, so the read that follows carries the switch's
        // old position — a flip that never happened must not paint over it.
        retire();
        return response.error;
      }, "settle");
      if (error !== null) report(error);
    } finally {
      // The write landed; the read behind it is the truth from here.
      retire();
    }
  };
}
