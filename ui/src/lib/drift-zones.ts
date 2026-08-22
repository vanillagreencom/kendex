import type { DriftCause, DriftRow } from "@/bindings";
import { type MergedDriftRow, mergeDriftRows } from "@/lib/drift-merge";

/** Files kendex did not write are at an item's place. Which ways out the
 *  row has differs by cause — core's own split, mirrored here because the
 *  page is what renders the buttons. */
const IN_THE_WAY: DriftCause[] = [
  "unmanaged-content",
  "unmanaged-wrong-shape",
  "shared-link",
];

export function isInTheWay(cause: DriftCause | null | undefined): boolean {
  return !!cause && IN_THE_WAY.includes(cause);
}

/** Whether the row can be settled at all without the reader moving files
 *  themselves. A foreign link cannot, and an item holding one has no exit
 *  — so it belongs on the same row, where it takes both buttons with it. */
export function blocksTheItem(cause: DriftCause | null | undefined): boolean {
  return isInTheWay(cause) || cause === "foreign-link";
}

/** Adoption can take what is at this position. */
export function canKeep(cause: DriftCause | null | undefined): boolean {
  return cause === "unmanaged-content" || cause === "shared-link";
}

/** Installing what kendex.toml asks for over it is an answer. */
export function canReplace(cause: DriftCause | null | undefined): boolean {
  return cause === "unmanaged-content" || cause === "unmanaged-wrong-shape";
}

/**
 * Which part of a project's card a drift row belongs in.
 *
 * The split is by what the reader can do about the row, not by what the
 * planner called it. An item whose files were already on disk is a conflict
 * like any other to the engine, but Apply cannot move it — only a person
 * saying which way it goes can — so it sits with the decisions rather than
 * under the button, where it would look like something Apply was about to
 * handle and then quietly not move.
 */
export interface DriftZones {
  /** Declared, with files already where they go. Two ways out, both on the row. */
  inTheWay: MergedDriftRow[];
  /** What the Apply button covers. */
  changes: MergedDriftRow[];
  /** On disk, declared by nothing. A footnote pointing at the Library. */
  unmanaged: MergedDriftRow[];
  /** Installed, nothing asks for it any more. */
  orphans: MergedDriftRow[];
}

const itemKey = (row: DriftRow) => `${row.kind}:${row.name}`;

export function driftZones(rows: DriftRow[]): DriftZones {
  // Every conflict an item with files in the way has, not only the rows
  // that carry them. Both exits act on the whole item and the engine
  // refuses one it could only half settle, so a hard conflict beside them
  // — a link kendex will not touch — belongs on the same row, where it
  // takes both buttons with it.
  const blocked = new Set(
    rows.filter((row) => isInTheWay(row.cause)).map(itemKey),
  );
  const inTheWay = rows.filter(
    (row) => blocksTheItem(row.cause) && blocked.has(itemKey(row)),
  );
  return {
    inTheWay: mergeDriftRows(inTheWay),
    changes: mergeDriftRows(
      rows.filter(
        (row) => row.state !== "unmanaged" && !inTheWay.includes(row),
      ),
    ),
    unmanaged: mergeDriftRows(rows.filter((row) => row.state === "unmanaged")),
    orphans: mergeDriftRows(rows.filter((row) => row.state === "orphaned")),
  };
}
