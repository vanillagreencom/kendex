import { useState } from "react";
import { commands, type DriftRow } from "@/bindings";
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
import { ADD_PROJECT_HELP } from "@/lib/copy";
import { harnessName, kindLabel } from "@/lib/labels";

/** Point kendex at one folder. */
export function AddProjectDialog({
  open,
  onOpenChange,
  registerProject,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  registerProject: (path: string) => Promise<boolean>;
}) {
  const [path, setPath] = useState("");
  const [adding, setAdding] = useState(false);
  // What the project already holds that nothing manages. Registering runs
  // the scan and says so here, rather than leaving it to be found on a
  // later visit to the Library.
  const [found, setFound] = useState<DriftRow[] | null>(null);

  const submit = () => {
    const trimmed = path.trim();
    if (!trimmed || adding) return;
    setAdding(true);
    void registerProject(trimmed).then((ok) => {
      setAdding(false);
      // A rejected path keeps the dialog open with what was typed still in
      // it — the error surfaces behind, and retyping a long path is worse
      // than reading it again.
      if (!ok) return;
      void commands.projectOffers(trimmed).then((r) => {
        const rows = r.status === "ok" ? r.data : [];
        setPath("");
        // Nothing to manage is nothing to say: the dialog closes on the
        // registration it was opened for.
        if (rows.length === 0) onOpenChange(false);
        else setFound(rows);
      });
    });
  };

  const close = () => {
    setFound(null);
    onOpenChange(false);
  };

  if (found) {
    return (
      <Dialog open={open} onOpenChange={close}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {found.length} item{found.length === 1 ? "" : "s"} here are not
              managed yet
            </DialogTitle>
            <DialogDescription>
              kendex leaves them exactly where they are. Manage one from Library
              › Installed to move it into the shared <code>.agents</code> home,
              with the path its tool reads left working.
            </DialogDescription>
          </DialogHeader>
          <ul className="flex max-h-64 flex-col gap-1 overflow-y-auto text-sm">
            {found.map((row) => (
              <li
                key={`${row.kind}:${row.name}:${row.harness}`}
                className="flex items-baseline gap-2"
              >
                <span>{row.name}</span>
                <span className="text-xs text-muted-foreground">
                  {kindLabel(row.kind)} · {harnessName(row.harness)}
                </span>
              </li>
            ))}
          </ul>
          <DialogFooter>
            <Button onClick={close}>Done</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    );
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Add a project</DialogTitle>
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
            placeholder="/path/to/project"
            value={path}
            onChange={setPath}
            disabled={adding}
            browseLabel="Browse for a project folder"
          />
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => onOpenChange(false)}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={adding || !path.trim()}>
              Add project
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
