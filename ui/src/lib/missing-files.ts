import { useMemo } from "react";
import type { UpdateRow } from "@/bindings";
import { PLACE_COUNTING_LABEL, PLACE_UNCHECKED_LABEL } from "@/lib/copy";
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

/** Those rows, or null where no read has answered for them.
 *
 *  Null rather than an empty array, because the two are different answers
 *  and a caller that cannot tell them apart states "none installed" over a
 *  read that failed. Since this branch, a package can be on this machine
 *  with no observation of it anywhere — these rows are the only thing that
 *  says so — and every definite count and every "nothing installed" claim
 *  is therefore a claim about this read as much as about the scan.
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

/** Why a count of installed packages cannot be stated, or null when it can.
 *
 *  The same answer {@link packagesUncounted} gives for the identity join,
 *  for the other read a row set now depends on: a package can be installed
 *  with no observation of it anywhere, so a number taken before these rows
 *  answered is one the list it opens contradicts. A read still on its way
 *  and one that failed are different answers and neither is a number.
 */
export function useMissingUncounted(): string | null {
  const rows = useMissingRows();
  const failed = useUpdatesStore((s) => s.read.status === "failed");
  if (rows !== null) return null;
  return failed ? PLACE_UNCHECKED_LABEL : PLACE_COUNTING_LABEL;
}
