import type { DriftRow, HarnessId, RowExits } from "@/bindings";
import { type MergedDriftRow, mergeDriftRows } from "@/lib/drift-merge";

/** The ways out of each blocked installation, looked up by row. Core works
 *  these out; this module groups and renders them, and never re-derives
 *  them from the cause — a page that did would drift from the plan the
 *  moment a cause was added. */
export class Exits {
  private readonly byKey: Map<string, RowExits>;

  constructor(exits: RowExits[]) {
    this.byKey = new Map(exits.map((exit) => [exit.key, exit]));
  }

  private of(row: DriftRow): RowExits | undefined {
    return this.byKey.get(`${row.kind}:${row.name}:${row.harness}`);
  }

  /** Whether this row stops every exit its item has. */
  blocking(row: DriftRow): boolean {
    return !!this.of(row)?.blocking;
  }

  /** Whether this place lets the item be kept. */
  keep(row: DriftRow): boolean {
    return !!this.of(row)?.keep;
  }

  /** Whether adoption acts through this tool. */
  enter(row: DriftRow): boolean {
    return !!this.of(row)?.enter;
  }

  /** Every tool keeping this row acts on, which is not always the tool
   *  the row is about. */
  tools(row: DriftRow): HarnessId[] {
    return this.of(row)?.tools ?? [row.harness];
  }

  /** Whether this row is about files sitting where the item installs. */
  files(row: DriftRow): boolean {
    return !!this.of(row)?.files;
  }

  /** Whether installing what kendex.toml asks for over it is an answer. */
  replace(row: DriftRow): boolean {
    return !!this.of(row)?.replace;
  }
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

export function driftZones(rows: DriftRow[], exits: Exits): DriftZones {
  // Items with files sitting where they install. Every conflict such an
  // item has belongs on its row — Apply cannot move any of them, and a
  // place nothing can settle takes the buttons off the ones beside it.
  // A conflict of another kind, alone, is not a decision about files.
  const withFiles = new Set(
    rows.filter((row) => exits.files(row)).map(itemKey),
  );
  const inTheWay = rows.filter(
    (row) => exits.blocking(row) && withFiles.has(itemKey(row)),
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
