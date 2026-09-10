import { useEffect, useState } from "react";
import type { HarnessId, SetupHeld } from "@/bindings";
import { PackageChecksDialog } from "@/components/harnesses/package-checks-dialog";
import { PackageChecksHelp } from "@/components/harnesses/package-checks-help";
import { Button } from "@/components/ui/button";
import {
  ENABLE_CHECKS_LABEL,
  heldBecause,
  INCOMPLETE_MEANS,
  notRunningIn,
  OFF_MEANS,
  ON_MEANS,
  PACKAGE_CHECKS_LABEL,
  PACKAGE_CHECKS_LIBRARY_LABEL,
  runsIn,
  STATE_INCOMPLETE,
  STATE_OFF,
  STATE_ON,
  STATE_UNKNOWN,
  UNKNOWN_MEANS,
} from "@/lib/copy-package-checks";
import { type ChecksStanding, enableChecks } from "@/lib/package-checks";

const STATE_WORDS: Record<ChecksStanding["state"], string> = {
  off: STATE_OFF,
  on: STATE_ON,
  incomplete: STATE_INCOMPLETE,
  unknown: STATE_UNKNOWN,
};

/** The one place the app offers a project's package checks: a line on the
 *  project's card naming the state, the help beside the name, and — while
 *  the checks are off and the project can be read — one button.
 *
 *  A project whose registered folder is missing, or whose state no read has
 *  established, keeps the line and loses the button: the information stays
 *  readable, and an action against a project kendex cannot see is never
 *  offered. The folder is found again through the card's own recovery, not
 *  by installing into the path that used to hold it. */
export function PackageChecksRow({
  name,
  root,
  standing,
  harnesses,
  onOpenLibrary,
}: {
  name: string;
  root: string;
  standing: ChecksStanding;
  /** The tools this installation registers the check in — the
   *  `PACKAGE_CHECK_HARNESSES` constant, so the row names no tool the
   *  install would skip. */
  harnesses: readonly HarnessId[];
  /** Where the check is turned off, removed, or seen beside whatever else
   *  is waiting here: this project's Library, narrowed to its hooks. */
  onOpenLibrary: () => void;
}) {
  const [asking, setAsking] = useState(false);
  const [busy, setBusy] = useState(false);
  // Why the last setup here stopped where it did. The scan that follows
  // the write says which tools are covered; nothing in it says whether
  // the rest are waiting on other changes or on a position that needs a
  // person, so the answer the write gave stays on the row.
  const [held, setHeld] = useState<SetupHeld | null>(null);
  // A reason describes the setup it was given about. Once a rescan finds
  // the checks running, that setup is finished and the reason is spent:
  // dropped rather than hidden, so a card that goes incomplete again
  // later cannot bring back an explanation of an earlier hold.
  useEffect(() => {
    if (standing.state === "on") setHeld(null);
  }, [standing.state]);
  const offerable = standing.state === "off";
  return (
    <div className="flex items-start justify-between gap-4 px-4">
      <div className="flex flex-col gap-0.5">
        <p className="flex items-center gap-1 text-[13px] text-muted-foreground">
          <span className="font-medium text-foreground">
            {PACKAGE_CHECKS_LABEL}
          </span>
          <PackageChecksHelp harnesses={harnesses} />
          {" · "}
          {STATE_WORDS[standing.state]}
        </p>
        <p className="text-[13px] text-muted-foreground">
          {means(standing.state)}
          {standing.running.length > 0 ? ` ${runsIn(standing.running)}` : ""}
          {standing.state === "incomplete" && standing.waiting.length > 0
            ? ` ${notRunningIn(standing.waiting)}`
            : ""}
        </p>
        {/* The guard keeps the render that reaches "on" from painting the
            reason for the frame before the effect above drops it. */}
        {held && standing.state !== "on" ? (
          <p className="text-[13px] text-muted-foreground">
            {heldBecause(held)}
          </p>
        ) : null}
      </div>
      {offerable ? (
        <Button
          variant="outline"
          size="sm"
          className="shrink-0"
          onClick={() => setAsking(true)}
        >
          {ENABLE_CHECKS_LABEL}
        </Button>
      ) : null}
      {standing.state === "on" || standing.state === "incomplete" ? (
        <Button
          variant="outline"
          size="sm"
          className="shrink-0"
          onClick={onOpenLibrary}
        >
          {PACKAGE_CHECKS_LIBRARY_LABEL}
        </Button>
      ) : null}
      <PackageChecksDialog
        open={asking}
        onOpenChange={(open) => {
          if (!busy) setAsking(open);
        }}
        project={name}
        root={root}
        busy={busy}
        onConfirm={() => {
          setBusy(true);
          void enableChecks(root, name)
            .then(setHeld)
            .finally(() => {
              setBusy(false);
              setAsking(false);
            });
        }}
      />
    </div>
  );
}

function means(state: ChecksStanding["state"]): string {
  switch (state) {
    case "off":
      return OFF_MEANS;
    case "on":
      return ON_MEANS;
    case "incomplete":
      return INCOMPLETE_MEANS;
    case "unknown":
      return UNKNOWN_MEANS;
  }
}
