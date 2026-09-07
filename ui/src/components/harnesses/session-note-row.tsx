import { useState } from "react";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { Button } from "@/components/ui/button";
import {
  ADD_SESSION_NOTE_LABEL,
  addSessionNoteTitle,
  SESSION_NOTE_CHANGES,
  SESSION_NOTE_LABEL,
  SESSION_NOTE_OFF,
  SESSION_NOTE_ON,
  SESSION_NOTE_WAITING,
  SESSION_NOTE_WHAT,
} from "@/lib/copy-session-note";
import { addSessionNote, type SessionNoteState } from "@/lib/session-note";

const STATE_TEXT: Record<SessionNoteState, string> = {
  off: SESSION_NOTE_OFF,
  on: SESSION_NOTE_ON,
  waiting: SESSION_NOTE_WAITING,
};

/** The one place the app offers the start-of-session note: a line on the
 *  project's card naming what agents here get and, while it is off, one
 *  button. The button opens a dialog that says what the note is and what
 *  changes on disk before it asks; the answer to the ask is the same
 *  words back on this line once the machine has been read again. */
export function SessionNoteRow({
  name,
  root,
  state,
}: {
  name: string;
  root: string;
  state: SessionNoteState;
}) {
  const [asking, setAsking] = useState(false);
  const [busy, setBusy] = useState(false);
  return (
    <div className="flex items-start justify-between gap-4 px-4">
      <p className="text-[13px] text-muted-foreground">
        <span className="font-medium text-foreground">
          {SESSION_NOTE_LABEL}
        </span>
        {" · "}
        {STATE_TEXT[state]}
      </p>
      {state === "off" ? (
        <Button
          variant="outline"
          size="sm"
          className="shrink-0"
          onClick={() => setAsking(true)}
        >
          {ADD_SESSION_NOTE_LABEL}
        </Button>
      ) : null}
      <ConfirmDialog
        open={asking}
        onOpenChange={(open) => {
          if (!busy) setAsking(open);
        }}
        title={addSessionNoteTitle(name)}
        description={SESSION_NOTE_WHAT}
        confirmLabel={ADD_SESSION_NOTE_LABEL}
        busy={busy}
        onConfirm={() => {
          setBusy(true);
          void addSessionNote(root, name).finally(() => {
            setBusy(false);
            setAsking(false);
          });
        }}
      >
        <p className="text-[13px] text-muted-foreground">
          {SESSION_NOTE_CHANGES}
        </p>
      </ConfirmDialog>
    </div>
  );
}
