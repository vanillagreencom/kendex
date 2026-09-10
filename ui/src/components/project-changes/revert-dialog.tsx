import { useEffect, useState } from "react";
import { commands, type Refused, type RestoreEffect } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { didNotFinish } from "@/lib/copy-commit-offer";
import {
  ADDED_LABEL,
  ADDED_NOTE,
  DROPPED_LABEL,
  DROPPED_NOTE,
  REMOVED_LABEL,
  REMOVED_NOTE,
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

/** What the preview read came back with. */
type Read =
  | { at: "reading" }
  | { at: "effect"; effect: RestoreEffect }
  | { at: "refused"; said: string[] };

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
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  root: string;
  /** The paths the reader chose to put back. */
  paths: string[];
  /** What the run did, for the surface that opened this. */
  onDone: (effect: RestoreEffect) => void;
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
    // over it would leave the reader believing the files went back.
    if (answer.at !== "effect") {
      setRead(answer);
      return;
    }
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
          <div className="space-y-1">
            <p className="font-medium text-critical">{REVERT_FAILED_TITLE}</p>
            <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-all rounded bg-muted p-2 font-mono text-xs">
              {read.said.join("\n")}
            </pre>
          </div>
        ) : nothing ? (
          <p className="text-muted-foreground">{REVERT_NOTHING}</p>
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
    | {
        status: "ok";
        data:
          | { kind: "effect"; effect: RestoreEffect }
          | { kind: "refused"; refused: Refused };
      }
    | { status: "error"; error: string },
): Read {
  if (response.status === "error")
    return { at: "refused", said: [response.error] };
  if (response.data.kind === "effect")
    return { at: "effect", effect: response.data.effect };
  const refused = response.data.refused;
  return {
    at: "refused",
    said: refused.timedOut ? [didNotFinish(refused.seconds)] : refused.said,
  };
}
