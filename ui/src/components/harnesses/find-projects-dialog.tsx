import { FolderSearch } from "lucide-react";
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
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  ADD_LABEL,
  ADD_THIS_FOLDER,
  ADDING_LABEL,
  ALREADY_ADDED,
  FIND_PROJECTS_ACTION,
  FIND_PROJECTS_BROWSE,
  FIND_PROJECTS_HELP,
  FIND_PROJECTS_PLACEHOLDER,
  FIND_PROJECTS_TITLE,
  foundProjects,
  NO_PROJECTS_FOUND,
  searchFailed,
  searchingIn,
} from "@/lib/copy-project-setup";
import type { Discovered } from "@/stores/settings-projects";

/** What the search has to say right now. The four states are told apart
 *  because a reader acts differently in each: wait, add one of these, add
 *  the folder itself, or try again. Nothing collapses a failure into an
 *  empty result — the folder kendex could not read may be full of
 *  projects. */
type Search =
  | { at: "idle" }
  | { at: "searching"; root: string }
  | { at: "found"; root: string; paths: string[] }
  | { at: "failed"; root: string; reason: string };

/** Look through a folder for projects that already have coding-tool setup,
 *  and add whichever the reader picks.
 *
 *  The secondary way in: Add a project is for one folder somebody already
 *  knows about. This one reads, and adds nothing by itself — which is what
 *  the sentence above the field says before a folder is chosen, because
 *  after it is chosen the search has already run. */
export function FindProjectsDialog({
  open,
  onOpenChange,
  projects,
  registerProject,
  discoverProjects,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** The roots already registered, so a result that is already a project
   *  says so instead of offering to add it again. */
  projects: string[];
  registerProject: (path: string) => Promise<boolean>;
  discoverProjects: (root: string) => Promise<Discovered>;
}) {
  const [root, setRoot] = useState("");
  const [search, setSearch] = useState<Search>({ at: "idle" });
  // Which results have a registration out. Per row rather than one flag:
  // a reader adds several from one result, and one shared flag would put
  // every other row's button into a state its own press did not cause.
  const [adding, setAdding] = useState<ReadonlySet<string>>(new Set());

  const find = (path: string) => {
    const trimmed = path.trim();
    if (!trimmed) return;
    setSearch({ at: "searching", root: trimmed });
    void discoverProjects(trimmed).then((result) => {
      setSearch(
        result.status === "found"
          ? { at: "found", root: trimmed, paths: result.paths }
          : { at: "failed", root: trimmed, reason: result.reason },
      );
    });
  };

  const add = (path: string) => {
    setAdding((held) => new Set(held).add(path));
    void registerProject(path).finally(() =>
      setAdding((held) => {
        const next = new Set(held);
        next.delete(path);
        return next;
      }),
    );
  };

  const close = (next: boolean) => {
    if (!next) setSearch({ at: "idle" });
    onOpenChange(next);
  };

  return (
    <Dialog open={open} onOpenChange={close}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{FIND_PROJECTS_TITLE}</DialogTitle>
          <DialogDescription>{FIND_PROJECTS_HELP}</DialogDescription>
        </DialogHeader>
        <form
          className="flex gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            find(root);
          }}
        >
          {/* Choosing a folder in the picker is the whole request, so it
              searches. A typed path is not: the field is still being
              filled in as it is typed, so it keeps its own action. */}
          <PathField
            id="find-projects-folder"
            placeholder={FIND_PROJECTS_PLACEHOLDER}
            value={root}
            onChange={setRoot}
            onPick={find}
            disabled={search.at === "searching"}
            browseLabel={FIND_PROJECTS_BROWSE}
          />
          <Button
            type="submit"
            variant="outline"
            disabled={search.at === "searching" || !root.trim()}
          >
            <FolderSearch className="size-4" />
            {FIND_PROJECTS_ACTION}
          </Button>
        </form>

        {/* Always a result: waiting, what was found, that nothing was, or
            why the folder could not be read. An empty panel would leave a
            press with nothing to show it landed. */}
        {search.at === "searching" ? (
          <Activity label={searchingIn(search.root)} />
        ) : null}
        {search.at === "failed" ? (
          <div className="space-y-2">
            <p className="text-sm text-critical" role="alert">
              {searchFailed(search.root)}
            </p>
            <p className="text-[13px] text-muted-foreground">{search.reason}</p>
            <Button
              size="sm"
              variant="outline"
              onClick={() => find(search.root)}
            >
              {TRY_AGAIN_LABEL}
            </Button>
          </div>
        ) : null}
        {search.at === "found" && search.paths.length === 0 ? (
          <div className="space-y-2">
            <p className="text-[13px] text-muted-foreground">
              {NO_PROJECTS_FOUND}
            </p>
            {/* The folder itself may be the project somebody meant, and
                offering it here saves closing this to open the other
                dialog and type the same path again. */}
            <Button
              size="sm"
              variant="outline"
              disabled={
                projects.includes(search.root) || adding.has(search.root)
              }
              onClick={() => add(search.root)}
            >
              {projects.includes(search.root)
                ? ALREADY_ADDED
                : adding.has(search.root)
                  ? ADDING_LABEL
                  : ADD_THIS_FOLDER}
            </Button>
          </div>
        ) : null}
        {search.at === "found" && search.paths.length > 0 ? (
          <div className="space-y-2">
            <p className="text-[13px] text-muted-foreground">
              {foundProjects(search.paths.length)}
            </p>
            <div className="max-h-64 overflow-y-auto">
              {search.paths.map((path) => (
                <div
                  key={path}
                  className="flex items-center justify-between gap-3 border-b border-border/40 py-2 last:border-0"
                >
                  <span className="truncate font-mono text-[13px] text-muted-foreground">
                    {path}
                  </span>
                  <Button
                    variant="outline"
                    size="sm"
                    disabled={projects.includes(path) || adding.has(path)}
                    onClick={() => add(path)}
                  >
                    {projects.includes(path)
                      ? ALREADY_ADDED
                      : adding.has(path)
                        ? ADDING_LABEL
                        : ADD_LABEL}
                  </Button>
                </div>
              ))}
            </div>
          </div>
        ) : null}

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => close(false)}>
            Done
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
