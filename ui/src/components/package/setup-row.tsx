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
 *  Active reads as settled and Needs repair as a warning: something here
 *  was set up and has broken.
 *
 *  Not active carries no tone. Declining the setup dialog is an answer,
 *  and the issue asks that it leave a neutral inactive status rather than
 *  a standing warning — an amber row over a choice somebody made reads as
 *  a reproach for making it. The states that say nothing was measured are
 *  untoned for the neighbouring reason: a warning over a state nobody read
 *  teaches people to distrust the colour, which is the rule `STATUS_TONES`
 *  exists to keep. */
export const toneOf: Record<SetupShown, StatusTone | null> = {
  checking: null,
  active: "good",
  notActive: null,
  needsRepair: "warning",
  couldNotCheck: null,
  unavailable: null,
  notDeclared: null,
  notARepository: null,
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
  refused,
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
  /** Why the command could not answer, or null. Printed as the row's
   *  cause where there is no answer to take one from. */
  refused: string | null;
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
  // Offered whenever the row is drawn at all, not only where a previous
  // answer said there was a check. A refused command leaves no answer to
  // read that from, and a row with no way to try again strands the reader
  // on the one state trying again is the remedy for.
  const canCheck = status === null || status.canCheck;
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
          {/* Why the command could not answer, where it did not. The
              only account of a place whose declaration will not read, so
              it is printed rather than folded into the state's word. */}
          {refused ? (
            <p className="mt-0.5 break-words font-mono text-xs text-muted-foreground">
              {refused}
            </p>
          ) : null}
          {/* What the check itself said, whatever it said. This is the
              remediation text somebody acts on, so a verdict never
              travels without it. */}
          {/* By position, because the lines are not distinct: a check may
              write the same warning twice, and keying on the text merges
              the pair into one row. The list is output in the order it was
              written and is never reordered or filtered, which is what
              makes the index the stable identity here. */}
          {status?.said.map((line, at) => (
            <p
              // biome-ignore lint/suspicious/noArrayIndexKey: output lines are not distinct and never reorder
              key={at}
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
