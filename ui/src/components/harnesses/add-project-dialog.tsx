import { useState } from "react";
import { Activity } from "@/components/activity";
import { PathField } from "@/components/harnesses/path-field";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  ADD_PROJECT_ACTION,
  ADD_PROJECT_BROWSE,
  ADD_PROJECT_HELP,
  ADD_PROJECT_PLACEHOLDER,
  ADD_PROJECT_TITLE,
  ADDING_PROJECT,
} from "@/lib/copy-project-setup";

/** Point kendex at one folder.
 *
 *  The dialog answers the registry write and closes on it. What the
 *  project already holds is read behind that, on the project's own card —
 *  a whole-machine read is seconds of work, and waiting for it here is
 *  what left this dialog on screen with a dead button, looking frozen.
 *  Nothing kendex found in the folder is reported here either: the card
 *  says how much is not managed, with the offer behind it. */
export function AddProjectDialog({
  open,
  onOpenChange,
  registerProject,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** True when the registry holds the project. Its own errors are reported
   *  where the store reports them; here a false only keeps the dialog. */
  registerProject: (path: string) => Promise<boolean>;
}) {
  const [path, setPath] = useState("");
  const [adding, setAdding] = useState(false);

  const submit = () => {
    const trimmed = path.trim();
    // The second press of a button whose first press is still out would
    // register the same folder twice; the guard is here rather than only
    // on the button because Enter in the field reaches the same submit.
    if (!trimmed || adding) return;
    setAdding(true);
    void registerProject(trimmed).then((ok) => {
      setAdding(false);
      // A rejected path keeps the dialog open with what was typed still in
      // it — the error surfaces behind, and retyping a long path is worse
      // than reading it again.
      if (!ok) return;
      setPath("");
      onOpenChange(false);
    });
  };

  return (
    <Dialog
      open={open}
      // Not dismissible while the write is out: the dialog is what holds
      // the path the write is for, and closing it mid-write would leave a
      // registration nobody can see the result of.
      onOpenChange={(next) => {
        if (!next && adding) return;
        onOpenChange(next);
      }}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{ADD_PROJECT_TITLE}</DialogTitle>
          <DialogDescription>{ADD_PROJECT_HELP}</DialogDescription>
        </DialogHeader>
        <form
          className="flex flex-col gap-3"
          onSubmit={(e) => {
            e.preventDefault();
            submit();
          }}
        >
          <PathField
            id="project-folder"
            placeholder={ADD_PROJECT_PLACEHOLDER}
            value={path}
            onChange={setPath}
            disabled={adding}
            browseLabel={ADD_PROJECT_BROWSE}
          />
          <DialogFooter>
            {/* Said where the press landed, so the wait has an account on
                screen rather than a button that stopped responding. */}
            {adding ? (
              <Activity className="mr-auto" label={ADDING_PROJECT} />
            ) : null}
            <Button
              type="button"
              variant="outline"
              disabled={adding}
              onClick={() => onOpenChange(false)}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={adding || !path.trim()}>
              {ADD_PROJECT_ACTION}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
