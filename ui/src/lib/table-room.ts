import { type RefObject, useLayoutEffect, useState } from "react";

/** What a table's optional columns cost it, in the pixels its own cells
 *  declare. Every table writes its own: the widths are the classes that
 *  table's headers carry, and the order is a judgement about that table's
 *  reader. Only the arithmetic below is shared. */
export interface ColumnBudget<Column extends string> {
  /** What the columns drawn at every width cost together, including the
   *  ceiling the name column's cell carries. */
  kept: number;
  /** What each optional column costs when it is drawn. */
  optional: Record<Column, number>;
  /** The order the columns come back in as the table's room grows, and in
   *  reverse the order it gives them up. */
  order: readonly Column[];
}

/** The columns `room` pixels can hold, out of the ones a table declares.
 *
 *  The columns a reader needs to tell one row from another and decide about
 *  it are the budget's `kept` sum: they stay at every width, and the rest
 *  are spent against what is left over. A `room` of null is a width nothing
 *  has measured yet: the table opens on everything it declares and narrows
 *  once its own layout has answered. */
export function afforded<Column extends string>(
  room: number | null,
  declared: Record<Column, boolean>,
  budget: ColumnBudget<Column>,
): Record<Column, boolean> {
  if (room === null) return declared;
  const shown = {} as Record<Column, boolean>;
  // Off first, from what the table declares rather than from the restore
  // order: a column the order forgot would otherwise come back as
  // undefined, which every reader of the result takes for off silently.
  for (const column of Object.keys(declared) as Column[]) shown[column] = false;
  let used = budget.kept;
  for (const column of budget.order) {
    if (!declared[column]) continue;
    used += budget.optional[column];
    if (used > room) break;
    shown[column] = true;
  }
  return shown;
}

/** How wide the element the ref is on is, kept current as it changes.
 *  Null until a layout has answered: a zero width is an element nothing has
 *  laid out yet, not a table with no room to give a column. */
export function useRoom(ref: RefObject<HTMLElement | null>): number | null {
  const [room, setRoom] = useState<number | null>(null);
  useLayoutEffect(() => {
    const element = ref.current;
    if (!element) return;
    // Read once here, before the browser paints. A ResizeObserver reports
    // even its first observation on a later task, so left to it alone the
    // table draws every column once at whatever width it has — which at a
    // narrow one is the cut this fixes, on screen for a frame.
    const measured = (width: number) => setRoom(width > 0 ? width : null);
    measured(element.getBoundingClientRect().width);
    const observer = new ResizeObserver((entries) => {
      measured(entries[0]?.contentRect.width ?? 0);
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, [ref]);
  return room;
}
