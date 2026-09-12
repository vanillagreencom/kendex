import { useMemo } from "react";
import type { UpdateRow } from "@/bindings";
import { rowsKnown } from "@/lib/updates-read-state";
import { useUpdatesStore } from "@/stores/updates";

/** The rows saying a file kendex recorded writing is gone from disk: the
 *  Library's badge, and the row it draws for a package no copy of which is
 *  left, are read from these. */
const missingFiles = (rows: UpdateRow[]): UpdateRow[] =>
  rows.filter((row) => row.filesMissing);

/** Those rows, or null where no read has answered for them.
 *
 *  Null rather than an empty array, because the two are different answers
 *  and a caller that cannot tell them apart states "none installed" over a
 *  read that failed. A package can be on this machine with no observation
 *  of it anywhere — these rows are the only thing that says so — so the
 *  Library's total and its empty state are claims about this read as much
 *  as about the scan.
 *
 *  Known on {@link rowsKnown}, the rule every reader of the per-place facts
 *  takes: a landed read, or a failed re-check over the rows it kept.
 *
 *  Memoized because it is grouped against: a fresh array every render
 *  re-groups the whole scan on every render. */
export function useMissingRows(): UpdateRow[] | null {
  const rows = useUpdatesStore((s) => s.rows);
  const known = useUpdatesStore(rowsKnown);
  return useMemo(() => (known ? missingFiles(rows) : null), [rows, known]);
}
