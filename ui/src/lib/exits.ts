import type { DriftRow, HarnessId, RowExits } from "@/bindings";

/** The ways out of each blocked installation, looked up by row. Core works
 *  these out; this module reads them back, and never re-derives one from
 *  the cause or the state. A page that did would drift from the plan the
 *  moment a cause was added, and draw a button the plan then refuses. */
export class Exits {
  private readonly byKey: Map<string, RowExits>;

  constructor(exits: RowExits[]) {
    this.byKey = new Map(exits.map((exit) => [exit.key, exit]));
  }

  private of(row: DriftRow): RowExits | undefined {
    return this.byKey.get(`${row.kind}:${row.name}:${row.harness}`);
  }

  /** Whether this row stops every exit its item has. False for a row core
   *  reported no answer for, which is how a caller tells the two apart. */
  blocking(row: DriftRow): boolean {
    return !!this.of(row)?.blocking;
  }

  /** Whether this row is about files sitting where the item installs. */
  files(row: DriftRow): boolean {
    return !!this.of(row)?.files;
  }

  /** Whether this place lets the item be kept. */
  keep(row: DriftRow): boolean {
    return !!this.of(row)?.keep;
  }

  /** Whether keeping acts through this tool. */
  enter(row: DriftRow): boolean {
    return !!this.of(row)?.enter;
  }

  /** Whether installing what kendex.toml asks for over it is an answer. */
  replace(row: DriftRow): boolean {
    return !!this.of(row)?.replace;
  }

  /** Every tool keeping this row acts on, which is not always the tool the
   *  row is about: a folder somebody shared by hand is read by whoever
   *  links at it, declared or not. */
  tools(row: DriftRow): HarnessId[] {
    return this.of(row)?.tools ?? [row.harness];
  }
}
