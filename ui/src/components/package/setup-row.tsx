import type { PackageSetup, SetupState } from "@/bindings";
import { DotSpinner } from "@/components/loading";
import { STATUS_TONES, type StatusTone } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import {
  ACTIVATE_LABEL,
  activateInLabel,
  CHECK_AGAIN_LABEL,
  checkAgainInLabel,
  REPAIR_LABEL,
  repairInLabel,
  SETUP_SHARED_NOTE,
  setupHeading,
  setupStateLabel,
  setupStateNote,
} from "@/lib/copy-setup";
import { cn } from "@/lib/utils";

/** What one project's setup row is showing: the answer, or the fact that
 *  nobody has one yet.
 *
 *  `checking` is its own value rather than a null answer, because those
 *  are different things to a reader: a read that is out will say
 *  something, and a read that failed already has. */
export type SetupShown = SetupState | "checking";

/** The state a row draws, given the entry the store holds for its place.
 *
 *  No entry and no read out is `checking`: the page asks for every place
 *  it draws the moment it opens, so the gap before the first answer is a
 *  read on its way. An entry whose command refused is `couldNotCheck` —
 *  kendex could not read the state, which is exactly that state and never
 *  an inactive one. */
export function shownState(
  entry: { setup: PackageSetup | null; reading: boolean } | undefined,
): SetupShown {
  if (entry === undefined || entry.reading) return "checking";
  return entry.setup?.status.state ?? "couldNotCheck";
}

/** The tone a state carries, from the app's own four, or none where the
 *  state is neutral.
 *
 *  Active is the only one that reads as settled. The two that need
 *  somebody are warnings. The two that say nothing was measured carry no
 *  tone at all: a warning over a state nobody read teaches people to
 *  distrust the colour, which is the rule `STATUS_TONES` exists to keep. */
const toneOf: Record<SetupShown, StatusTone | null> = {
  checking: null,
  active: "good",
  notActive: "warning",
  needsRepair: "warning",
  couldNotCheck: null,
  unavailable: null,
  notDeclared: null,
};

const toneClass = (state: SetupShown): string => {
  const tone = toneOf[state];
  return tone === null ? "text-muted-foreground" : STATUS_TONES[tone].text;
};

/** One project's line about one package's setup: what the package changes
 *  about the repository, whether it is doing it here, and the one or two
 *  things you can do about that in this project alone.
 *
 *  Every control names the project it reaches, in its spoken label and in
 *  the path printed above it, so a click can never be mistaken for
 *  activation everywhere. */
export function SetupRow({
  place,
  setup,
  state,
  busy,
  onActivate,
  onRepair,
  onCheckAgain,
}: {
  /** What this place is called among the package's places. */
  place: string;
  /** The last answer, or null where there is none yet or none could be
   *  read. The package's own summary and words come from here. */
  setup: PackageSetup | null;
  state: SetupShown;
  busy: boolean;
  onActivate: () => void;
  onRepair: () => void;
  onCheckAgain: () => void;
}) {
  const status = setup?.status ?? null;
  const summary = setup?.disclosure?.summary ?? null;
  const note = setupStateNote(state);
  // Offered only where the package declares something to run. A button the
  // engine would refuse is worse than no button — the same rule the update
  // and removal controls on this card are held to.
  const canApply = status?.canApply === true;
  const canCheck = status?.canCheck === true;
  const repairing = state === "needsRepair";
  const offerApply =
    canApply && (state === "notActive" || repairing || state === "unavailable");
  return (
    <div className="mt-3 border-t pt-3">
      <div className="flex items-start justify-between gap-4">
        <div className="min-w-0">
          <p className="text-[13px] font-medium">
            {setupHeading(place)}
            <span className={cn("ml-2 font-normal", toneClass(state))}>
              {state === "checking" ? (
                <span className="inline-flex items-center gap-1.5">
                  <DotSpinner />
                  {setupStateLabel(state)}
                </span>
              ) : (
                setupStateLabel(state)
              )}
            </span>
          </p>
          {/* The package's own line about what it changes, printed as core
              escaped it. kendex never explains what a declaration means. */}
          {summary ? (
            <p className="mt-0.5 text-[13px] text-muted-foreground">
              {summary}
            </p>
          ) : null}
          {note ? (
            <p className="mt-0.5 text-[13px] text-muted-foreground">{note}</p>
          ) : null}
          {/* Beside the button that would change it, and nowhere else:
              this is what somebody about to press Set up or Repair needs
              to know, and on a settled row it is one line too many. */}
          {status?.shared === true && offerApply ? (
            <p className="mt-0.5 text-[13px] text-muted-foreground">
              {SETUP_SHARED_NOTE}
            </p>
          ) : null}
          {/* What the check itself said, whatever it said. This is the
              remediation text somebody acts on, so a verdict never
              travels without it. */}
          {status?.said.map((line) => (
            <p
              key={line}
              className="mt-0.5 break-words font-mono text-xs text-muted-foreground"
            >
              {line}
            </p>
          ))}
        </div>
        <div className="flex shrink-0 items-center gap-2">
          {offerApply ? (
            <Button
              size="sm"
              disabled={busy}
              aria-label={
                repairing ? repairInLabel(place) : activateInLabel(place)
              }
              onClick={repairing ? onRepair : onActivate}
            >
              {repairing ? REPAIR_LABEL : ACTIVATE_LABEL}
            </Button>
          ) : null}
          {canCheck ? (
            <Button
              size="sm"
              variant="outline"
              disabled={busy || state === "checking"}
              aria-label={checkAgainInLabel(place)}
              onClick={onCheckAgain}
            >
              {CHECK_AGAIN_LABEL}
            </Button>
          ) : null}
        </div>
      </div>
    </div>
  );
}
