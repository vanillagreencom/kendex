import { useEffect, useState } from "react";
import type { Relocation } from "@/bindings";
import { Activity } from "@/components/activity";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { afterReconnect } from "@/lib/after-reconnect";
import {
  CHECKING_FOLDER,
  CLOSE_LABEL,
  LOCATE_CHOOSE_ANOTHER,
  LOCATE_CONFIRM,
  LOCATE_JOIN,
  LOCATE_PICKED,
  LOCATE_RECORDED,
  LOCATE_TITLE,
  LOCATING,
  locateHelp,
  RECONNECT_CLEAN,
  RECONNECT_UNCHECKED,
  reconnected,
  reconnectProblems,
  SEE_PROBLEMS,
  standingSaid,
} from "@/lib/copy-project-move";
import { pickFolder } from "@/lib/pick-folder";
import { useNavStore } from "@/stores/nav";
import {
  useBlockedPlaces,
  useProblems,
  useUnreadableFiles,
} from "@/stores/problems";
import { useSettingsStore } from "@/stores/settings";

/** One folder path, labelled — the two the reader is being asked to
 *  compare, drawn the same way so the difference between them is the only
 *  thing that stands out. */
function PathRow({ label, path }: { label: string; path: string }) {
  return (
    <div className="min-w-0">
      <p className="text-[13px] text-muted-foreground">{label}</p>
      <p className="break-all font-mono text-[13px]">{path}</p>
    </div>
  );
}

/**
 * Point a project at the folder it was moved to.
 *
 * The folder chooser opens where the reader pressed the button, so this
 * opens with a folder already picked and asks about that one. What the
 * folder holds is read before anything is written, and the answer is on
 * screen beside both paths: which project a folder belongs to is not
 * something its name can be trusted to decide. The write refuses the same
 * set of answers on its own, so what this explains and what the registry
 * allows cannot come apart.
 *
 * Nothing here writes to either folder. A reconnect that lands says what
 * the fresh read then found at the new place, and leaves fixing it to the
 * page that already offers it.
 */
export function LocateFolderDialog({
  root,
  name,
  picked,
  onClose,
}: {
  /** The folder the registry has now. */
  root: string;
  /** What the project is called on its card. */
  name: string;
  /** The folder the reader chose, which this dialog is about. */
  picked: string;
  onClose: () => void;
}) {
  const projectRelocation = useSettingsStore((s) => s.projectRelocation);
  const relocateProject = useSettingsStore((s) => s.relocateProject);
  const goTo = useNavStore((s) => s.goTo);
  const problems = useProblems();
  const blocked = useBlockedPlaces();
  // The scan's own half of what Problems draws for a place: a file it
  // could not read is a repair there and is in no audit row.
  const unreadable = useUnreadableFiles();
  const [asking, setAsking] = useState(picked);
  const [plan, setPlan] = useState<Relocation | null>(null);
  const [working, setWorking] = useState(false);
  const [done, setDone] = useState<string | null>(null);

  // One read per folder asked about, and the answer belongs to that
  // folder: a reply for a folder the reader has since replaced is dropped
  // rather than drawn under the new path.
  useEffect(() => {
    let current = true;
    setPlan(null);
    void projectRelocation(root, asking).then((found) => {
      if (current && found) setPlan(found);
    });
    return () => {
      current = false;
    };
  }, [root, asking, projectRelocation]);

  const choose = async () => {
    const next = await pickFolder();
    // Cancelling the chooser leaves the answer already on screen: the
    // reader asked to look at another folder, not to give up on this one.
    if (next) setAsking(next);
  };

  const reconnect = async () => {
    if (!plan) return;
    setWorking(true);
    // Joining two entries is the one thing that needs the person's own
    // answer, and which folders those are is core's to say: the dialog
    // presses what it was offered rather than reclassifying the standing.
    const now = await relocateProject(
      root,
      plan.to,
      plan.confirm === "consolidate",
    );
    setWorking(false);
    if (now) setDone(now);
  };

  const settled =
    done === null ? null : afterReconnect(problems, blocked, unreadable, done);

  return (
    <Dialog
      open
      onOpenChange={(next) => {
        // Not dismissible while the write is out: the dialog holds what the
        // write is about, and closing it would leave a reconnect nobody can
        // see the result of.
        if (!next && !working) onClose();
      }}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{LOCATE_TITLE}</DialogTitle>
          <DialogDescription>{locateHelp(name)}</DialogDescription>
        </DialogHeader>
        {done !== null && settled ? (
          <div className="flex flex-col gap-2">
            <p className="text-sm">{reconnected(name, done)}</p>
            <p className="text-[13px] text-muted-foreground">
              {settled.state === "clean"
                ? RECONNECT_CLEAN
                : settled.state === "unchecked"
                  ? RECONNECT_UNCHECKED
                  : reconnectProblems(settled.count)}
            </p>
          </div>
        ) : (
          <div className="flex flex-col gap-3">
            <PathRow label={LOCATE_RECORDED} path={root} />
            <PathRow label={LOCATE_PICKED} path={plan?.to ?? asking} />
            {plan ? (
              <p className="text-sm">{standingSaid(plan.standing, name)}</p>
            ) : (
              <Activity label={CHECKING_FOLDER} />
            )}
          </div>
        )}
        <DialogFooter>
          {working ? <Activity className="mr-auto" label={LOCATING} /> : null}
          {done !== null ? (
            <>
              {settled?.state === "problems" ? (
                <Button
                  variant="outline"
                  onClick={() => {
                    goTo("problems");
                    onClose();
                  }}
                >
                  {SEE_PROBLEMS}
                </Button>
              ) : null}
              <Button onClick={onClose}>{CLOSE_LABEL}</Button>
            </>
          ) : (
            <>
              <Button
                type="button"
                variant="outline"
                disabled={working}
                onClick={onClose}
              >
                Cancel
              </Button>
              <Button
                type="button"
                variant="outline"
                disabled={working}
                onClick={() => void choose()}
              >
                {LOCATE_CHOOSE_ANOTHER}
              </Button>
              {plan && plan.confirm !== "none" ? (
                <Button
                  type="button"
                  disabled={working}
                  onClick={() => void reconnect()}
                >
                  {plan.confirm === "consolidate"
                    ? LOCATE_JOIN
                    : LOCATE_CONFIRM}
                </Button>
              ) : null}
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
