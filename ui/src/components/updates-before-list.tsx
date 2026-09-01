import { CheckCircle2, TriangleAlert } from "lucide-react";
import type { ReactNode } from "react";
import { EmptyState } from "@/components/empty-state";
import { DotSpinner } from "@/components/loading";
import { Button } from "@/components/ui/button";
import {
  CHECK_FOR_UPDATES_LABEL,
  UPDATES_ATTENTION_TITLE,
  UPDATES_EMPTY,
  UPDATES_EMPTY_BODY,
} from "@/lib/copy";
import { UPDATES_CHECKING } from "@/lib/copy-updates";
import type { ReadState } from "@/lib/read-state";

/** What the Updates page shows while there is no list to show, or null
 *  once there is one. Three different answers that must never blur: a
 *  first read still on its way, a read that failed with nothing kept from
 *  a better one, and a completed error-free read that found nothing —
 *  only the last may say "Everything is up to date". */
export function updatesBeforeList({
  read,
  empty,
  checking,
  busy,
  lastChecked,
  onCheck,
}: {
  read: ReadState;
  empty: boolean;
  checking: boolean;
  /** True while a write is out. The store refuses a check on it, so this
   *  button says so — `updateRows` clearing the last visible row renders
   *  this empty state while its own write still holds the flag. */
  busy: boolean;
  /** How old the answer behind this page is, already worded. */
  lastChecked: string;
  onCheck: () => void;
}): ReactNode | null {
  const retry = (
    <Button variant="outline" disabled={checking || busy} onClick={onCheck}>
      {CHECK_FOR_UPDATES_LABEL}
    </Button>
  );
  // Before the first read answers there is nothing to report either way —
  // "Everything is up to date" here would assert an up-to-dateness nobody
  // has checked yet.
  if (read.status === "pending") {
    return (
      <div className="flex min-h-full items-center justify-center">
        <p className="flex items-center gap-2 text-sm text-muted-foreground">
          <DotSpinner />
          {UPDATES_CHECKING}
        </p>
      </div>
    );
  }
  // A read that failed with nothing kept from a better one: the page says
  // so and offers the retry — the same claim Home's attention row makes,
  // answered here where the row sends people.
  if (read.status === "failed" && empty) {
    return (
      <div className="flex min-h-full items-center justify-center">
        <EmptyState
          icon={TriangleAlert}
          title={UPDATES_ATTENTION_TITLE}
          action={retry}
        >
          {read.error}
        </EmptyState>
      </div>
    );
  }
  // With nothing to update there is nothing to introduce: a title and a
  // sentence explaining a list that isn't there is furniture around good
  // news. The sidebar already says which page this is. The age of the
  // check is the exception — this is the page where a stale answer looks
  // exactly like a current one, so the good news says how old it is.
  if (empty) {
    return (
      <div className="flex min-h-full items-center justify-center">
        <EmptyState icon={CheckCircle2} title={UPDATES_EMPTY} action={retry}>
          {`${UPDATES_EMPTY_BODY} ${lastChecked}.`}
        </EmptyState>
      </div>
    );
  }
  return null;
}
