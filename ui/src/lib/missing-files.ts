import { useMemo } from "react";
import type { UpdateRow } from "@/bindings";
import { rowsKnown } from "@/lib/updates-read-state";
import { useUpdatesStore } from "@/stores/updates";

/** The rows saying a file kendex recorded writing is gone from disk.
 *
 *  One answer for every surface that speaks about a missing rendering:
 *  Home's attention row and its Installed count, the Library's badge and
 *  the row it draws for a package no copy of which is left. A second
 *  spelling of this filter is how two of them come to disagree about
 *  whether a package is there. */
export const missingFiles = (rows: UpdateRow[]): UpdateRow[] =>
  rows.filter((row) => row.filesMissing);

/** Those rows for a component, or none while nothing has confirmed them.
 *
 *  Read on {@link rowsKnown}, the rule every reader of the per-place facts
 *  takes: a landed read, or a failed re-check over the rows it kept. A read
 *  still on its way has counted nothing, and drawing a row or a count off
 *  it would state as a fact what no read has answered.
 *
 *  Memoized because it is grouped against: a fresh array every render
 *  re-groups the whole scan on every render. */
export function useMissingRows(): UpdateRow[] {
  const rows = useUpdatesStore((s) => s.rows);
  const known = useUpdatesStore(rowsKnown);
  return useMemo(() => (known ? missingFiles(rows) : []), [rows, known]);
}
