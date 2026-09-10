import { useEffect, useState } from "react";
import { commands, type RestoreEffect, type RestoreResult } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { didNotFinish } from "@/lib/copy-commit-offer";
import {
  ADDED_LABEL,
  ADDED_NOTE,
  DROPPED_LABEL,
  DROPPED_NOTE,
  PARTIAL_NOTE,
  PARTIAL_REST_NOTE,
  REMOVED_LABEL,
  REMOVED_NOTE,
  RERENDERED_LABEL,
  RERENDERED_NOTE,
  RESTORED_LABEL,
  REVERT_CONFIRM_LABEL,
  REVERT_FAILED_TITLE,
  REVERT_NOT_REGENERATE,
  REVERT_NOTHING,
  REVERT_READING,
  REVERT_STANDING,
  REVERT_TITLE,
} from "@/lib/copy-project-changes";
import { readOrder } from "@/lib/read-state";

/** What the preview read, or the run, came back with. A refusal carries what
 *  had already been written when it stopped: a restore writes in two passes
 *  and a failure in the second leaves the first standing, so a bare refusal
 *  would tell a person nothing happened while their files had moved. */
type Read =
  | { at: "reading" }
  | { at: "effect"; effect: RestoreEffect }
  | { at: "refused"; said: string[]; done: RestoreEffect | null };

/** Putting chosen files back to what the last commit holds, with the exact
 *  effect stated before anything runs.
 *
 *  The preview is the same value the run reports, derived by the same call,
 *  so the confirmation describes what will happen rather than guessing
 *  beside it. Core derives it again when the run starts: a preview a person
 *  reads for a while describes a project that may have moved on, and the
 *  run may never take a path the offer has stopped covering.
 *
 *  Three effects, said apart. A file the last commit holds gets that
 *  version back. A file it does not hold — one kendex added — is taken
 *  away, and kendex takes nothing away by deleting: it moves to the trash.
 *  A file that has changed back since kendex looked is left out and named. */
export function RevertDialog({
  open,
  onOpenChange,
  root,
  paths,
  onDone,
  onPartial,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  root: string;
  /** The paths the reader chose to put back. */
  paths: string[];
  /** What the run did, for the surface that opened this. */
  onDone: (effect: RestoreEffect) => void;
  /** The run stopped part-way and left work on disk. The surface refreshes
   *  what it draws without claiming the restore succeeded — this dialog
   *  stays open with git's words and the account of what did move. */
  onPartial: (done: RestoreEffect) => void;
}) {
  const [read, setRead] = useState<Read>({ at: "reading" });
  const [running, setRunning] = useState(false);
  // One ticket per preview, and only the newest may write: opening this on
  // one file, closing it and opening it on another leaves two reads out
  // about different sets, and the older one landing last would describe an
  // effect on files the reader is no longer looking at.
  const [order] = useState(readOrder);

  useEffect(() => {
    if (!open) return;
    const ticket = order.begin();
    setRead({ at: "reading" });
    void commands.projectChangesRestorePlan(root, paths).then((response) => {
      if (!order.lands(ticket)) return;
      setRead(answerOf(response));
    });
  }, [open, root, paths, order]);

  const effect = read.at === "effect" ? read.effect : null;
  const nothing =
    effect !== null &&
    effect.restored.length === 0 &&
    effect.removed.length === 0;

  const run = async () => {
    setRunning(true);
    const response = await commands.projectChangesRestore(root, paths);
    setRunning(false);
    const answer = answerOf(response);
    // A refusal keeps the dialog open with git's own words in it: closing
    // over it would leave the reader believing the files went back. Where it
    // stopped part-way, what did move is on screen above those words AND the
    // surface behind is told to read the project again, so the page never
    // draws a set the run has already changed.
    if (answer.at === "refused") {
      setRead(answer);
      if (answer.done !== null && !empty(answer.done)) onPartial(answer.done);
      return;
    }
    if (answer.at !== "effect") return;
    onOpenChange(false);
    onDone(answer.effect);
  };

  return (
    <ConfirmDialog
      open={open}
      onOpenChange={onOpenChange}
      title={REVERT_TITLE}
      description={REVERT_STANDING}
      confirmLabel={REVERT_CONFIRM_LABEL}
      destructive
      busy={running}
      confirmDisabled={effect === null || nothing}
      confirmDisabledNote={read.at === "reading" ? REVERT_READING : undefined}
      onConfirm={() => void run()}
    >
      <div className="space-y-4 text-sm">
        {read.at === "reading" ? (
          <p className="text-muted-foreground">{REVERT_READING}</p>
        ) : read.at === "refused" ? (
          <div className="space-y-3">
            <p className="font-medium text-critical">{REVERT_FAILED_TITLE}</p>
            {/* What did move, before git's words rather than after them: a
                reader who has just been told the restore failed needs to
                know their files moved anyway. Nothing is drawn where the
                run stopped before writing. */}
            {read.done && !empty(read.done) ? (
              <div className="space-y-3">
                <p>{PARTIAL_NOTE}</p>
                <Group
                  label={RESTORED_LABEL}
                  paths={read.done.restored}
                  note={null}
                />
                <Group
                  label={REMOVED_LABEL}
                  paths={read.done.removed}
                  note={null}
                />
                <p className="text-muted-foreground">{PARTIAL_REST_NOTE}</p>
              </div>
            ) : null}
            <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-all rounded bg-muted p-2 font-mono text-xs">
              {read.said.join("\n")}
            </pre>
          </div>
        ) : nothing ? (
          // Nothing would be written, and the names still belong on screen:
          // the reader picked these files, and a preview of the exact effect
          // that hides which ones changed back leaves them to guess. The
          // confirmation stays disabled — there is nothing to confirm.
          <div className="space-y-3">
            <Group
              label={DROPPED_LABEL}
              paths={effect?.dropped ?? []}
              note={DROPPED_NOTE}
            />
            <p className="text-muted-foreground">{REVERT_NOTHING}</p>
          </div>
        ) : (
          <>
            <Group
              label={RESTORED_LABEL}
              paths={effect?.restored ?? []}
              note={null}
            />
            <Group
              label={REMOVED_LABEL}
              paths={effect?.removed ?? []}
              note={REMOVED_NOTE}
            />
            <Group
              label={ADDED_LABEL}
              paths={effect?.added ?? []}
              note={ADDED_NOTE}
            />
            <Group
              label={DROPPED_LABEL}
              paths={effect?.dropped ?? []}
              note={DROPPED_NOTE}
            />
            {/* Said with the rest of the effect rather than after the
                confirmation: a removal the next write undoes is not the
                effect the other groups describe. */}
            <Group
              label={RERENDERED_LABEL}
              paths={effect?.rerendered ?? []}
              note={RERENDERED_NOTE}
            />
            <p className="text-muted-foreground">{REVERT_NOT_REGENERATE}</p>
          </>
        )}
      </div>
    </ConfirmDialog>
  );
}

/** One group of the effect, drawn only where it holds anything: a heading
 *  over an empty list is a state the reader has to work out is empty. */
function Group({
  label,
  paths,
  note,
}: {
  label: string;
  paths: string[];
  note: string | null;
}) {
  if (paths.length === 0) return null;
  return (
    <section className="space-y-1">
      <h3 className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
        {label}
      </h3>
      <ul className="max-h-40 overflow-y-auto font-mono text-xs">
        {paths.map((path) => (
          <li key={path} className="break-all">
            {path}
          </li>
        ))}
      </ul>
      {note ? <p className="text-muted-foreground">{note}</p> : null}
    </section>
  );
}

/** One command answer as the dialog's state. A transport failure is a step
 *  that would not run, said the way a git refusal is: neither leaves the
 *  dialog able to state an effect. */
function answerOf(
  response:
    | { status: "ok"; data: RestoreResult }
    | { status: "error"; error: string },
): Read {
  // A transport failure is not an account of the repository: it says nothing
  // about what was written, so it carries no `done` rather than an empty one.
  if (response.status === "error")
    return { at: "refused", said: [response.error], done: null };
  if (response.data.kind === "effect")
    return { at: "effect", effect: response.data.effect };
  const refused = response.data.refused;
  return {
    at: "refused",
    said: refused.timedOut ? [didNotFinish(refused.seconds)] : refused.said,
    done: response.data.done,
  };
}

/** Whether an effect changed nothing on disk. */
const empty = (effect: RestoreEffect): boolean =>
  effect.restored.length === 0 && effect.removed.length === 0;
