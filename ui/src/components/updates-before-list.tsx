import { CheckCircle2, Package, RefreshCw, TriangleAlert } from "lucide-react";
import type { ReactNode } from "react";
import { EmptyState } from "@/components/empty-state";
import { DotSpinner } from "@/components/loading";
import { Button } from "@/components/ui/button";
import {
  BROWSE_MARKETPLACES_LABEL,
  CHECK_FOR_UPDATES_LABEL,
  UPDATES_ATTENTION_TITLE,
  UPDATES_EMPTY,
  UPDATES_EMPTY_BODY,
  UPDATES_NOTHING_INSTALLED,
  UPDATES_NOTHING_INSTALLED_BODY,
  UPDATES_UNCHECKED_BODY,
} from "@/lib/copy";
import { NEVER_CHECKED, UPDATES_CHECKING } from "@/lib/copy-updates";
import type { ReadState } from "@/lib/read-state";
import type { EmptyStanding } from "@/lib/updates-read-state";

/** What the Updates page shows while there is no list to show, or null
 *  once there is one. Five answers that must never blur: a first read still
 *  on its way, one that failed with nothing kept, a machine with nothing
 *  installed, one no check has reached a source for, and one a check found
 *  current — only the last may say "Everything is up to date". */
export function updatesBeforeList({
  read,
  standing,
  empty,
  checking,
  busy,
  lastChecked,
  onCheck,
  onBrowse,
}: {
  read: ReadState;
  /** What an empty list means, once the read has nothing left to say. */
  standing: EmptyStanding;
  empty: boolean;
  checking: boolean;
  /** True while a write is out. The store refuses a check on it, so this
   *  button says so — `updateRows` clearing the last visible row renders
   *  this empty state while its own write still holds the flag. */
  busy: boolean;
  /** How old the answer behind this page is, already worded. */
  lastChecked: string;
  onCheck: () => void;
  /** Where a machine with nothing installed is sent. */
  onBrowse: () => void;
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
  if (empty) {
    return (
      <div className="flex min-h-full items-center justify-center">
        {emptyAnswer(standing, { retry, lastChecked, onBrowse })}
      </div>
    );
  }
  return null;
}

/** The one empty answer this machine is owed, drawn from the standing so
 *  the three cannot be reached two ways. The age of the check travels with
 *  the good news: here a stale answer looks exactly like a current one. */
function emptyAnswer(
  standing: EmptyStanding,
  {
    retry,
    lastChecked,
    onBrowse,
  }: { retry: ReactNode; lastChecked: string; onBrowse: () => void },
): ReactNode {
  switch (standing.kind) {
    // No check can bring news to an empty machine: the way on is a
    // package, not the retry.
    case "nothing-installed":
      return (
        <EmptyState
          icon={Package}
          title={UPDATES_NOTHING_INSTALLED}
          action={
            <Button variant="outline" onClick={onBrowse}>
              {BROWSE_MARKETPLACES_LABEL}
            </Button>
          }
        >
          {UPDATES_NOTHING_INSTALLED_BODY}
        </EmptyState>
      );
    // Nothing has reached a source, so the check is the offer and
    // up-to-dateness is not.
    case "unchecked":
      return (
        <EmptyState icon={RefreshCw} title={NEVER_CHECKED} action={retry}>
          {UPDATES_UNCHECKED_BODY}
        </EmptyState>
      );
    case "current":
      return (
        <EmptyState icon={CheckCircle2} title={UPDATES_EMPTY} action={retry}>
          {`${UPDATES_EMPTY_BODY} ${lastChecked}.`}
        </EmptyState>
      );
  }

  // A fourth standing has to be answered above before this compiles.
  const unanswered: never = standing;
  return unanswered;
}
