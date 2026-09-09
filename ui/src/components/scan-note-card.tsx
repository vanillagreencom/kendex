import type { ScanWarning } from "@/bindings";
import { PlaceCard } from "@/components/place-card";
import { scanNoteDetail, scanNoteTitle } from "@/lib/copy-scan";
import { harnessName } from "@/lib/labels";

/** A file the scan found empty where kendex manages nothing in it: whose
 *  it is, where it is, and why nothing is missing. The same card shape as
 *  every other row on the page and none of the buttons — the file belongs
 *  to another program and there is nothing here for the reader to change. */
export function ScanNoteCard({ warning }: { warning: ScanWarning }) {
  return (
    <PlaceCard
      tone="info"
      headline={scanNoteTitle(warning)}
      name={harnessName(warning.harness)}
      path={warning.path}
    >
      <p className="text-sm">{scanNoteDetail(warning)}</p>
    </PlaceCard>
  );
}
