import { DotSpinner } from "@/components/loading";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import {
  PACKAGES_CHECK_FAILED_TITLE,
  PACKAGES_UNCONFIRMED_TITLE,
  PLACE_COUNTING_LABEL,
  TRY_AGAIN_LABEL,
} from "@/lib/copy";
import {
  usePackagesEverKnown,
  usePackagesKnown,
  usePackagesRead,
  useReloadPackages,
} from "@/lib/package-identity";

/** What to say while the read that says which installations are one
 *  package cannot answer for the scan on screen, or null where it can.
 *
 *  One component rather than a block per surface: the Library and a
 *  package page face the same three states — still on its way, failed with
 *  nothing behind it, failed over rows kept from before — and two spellings
 *  of them would sooner or later describe one state two ways.
 *
 *  Rows kept from an earlier answer are drawn as last-known and never as
 *  facts, which is the tone: critical where there is nothing behind the
 *  failure, a warning where there is. */
export function PackagesNote({ counting = false }: { counting?: boolean }) {
  const known = usePackagesKnown();
  const everKnown = usePackagesEverKnown();
  const read = usePackagesRead();
  const reload = useReloadPackages();

  if (read.status === "failed") {
    const nothingBehindIt = !everKnown;
    return (
      <StatusNote
        tone={nothingBehindIt ? "critical" : "warning"}
        title={
          nothingBehindIt
            ? PACKAGES_CHECK_FAILED_TITLE
            : PACKAGES_UNCONFIRMED_TITLE
        }
        action={
          <Button size="sm" variant="outline" onClick={() => void reload()}>
            {TRY_AGAIN_LABEL}
          </Button>
        }
      >
        {read.error}
      </StatusNote>
    );
  }
  // Still on its way. Only where the caller has nothing else to draw: a
  // page that can show its rows says so with its own skeleton instead.
  if (counting && !known) {
    return (
      <p className="flex items-center gap-2 text-sm text-muted-foreground">
        <DotSpinner />
        {PLACE_COUNTING_LABEL}
      </p>
    );
  }
  return null;
}
