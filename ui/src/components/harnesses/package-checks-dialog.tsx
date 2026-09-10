import { ChevronDown, ChevronRight } from "lucide-react";
import { useEffect, useId, useState } from "react";
import type { PlannedFile, SetupPlan } from "@/bindings";
import { commands } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { FileBrowser } from "@/components/files/file-browser";
import { FilePane } from "@/components/files/file-pane";
import { Button } from "@/components/ui/button";
import {
  CHANGE_WORDS,
  CHECKS_CONFLICTS_NOTE,
  CHECKS_QUIET,
  CHECKS_WHEN,
  CONFLICTS_LABEL,
  ENABLE_CHECKS_LABEL,
  enableChecksTitle,
  FILES_DISCLOSURE_LABEL,
  FILES_TREE_LABEL,
  NO_PREVIEW_WORDS,
  otherChangesWaiting,
  PACKAGE_CHECKS_PURPOSE,
  PLAN_FAILED,
  PLAN_PENDING,
  ROLE_WORDS,
  roleMeans,
} from "@/lib/copy-package-checks";

/** What the read of the plan produced. `null` while it runs; the refusal's
 *  own words when it failed, because a dialog that offers to write files it
 *  could not list is offering something nobody can check. */
type Read = { plan: SetupPlan } | { failed: string } | null;

/** The one ask before package checks are switched on in a project.
 *
 *  Purpose and project first, then what the hook does and does not do, then
 *  — behind a disclosure — every file the action writes, read from the plan
 *  that would write them rather than described from memory. Opening it
 *  reads; it writes nothing, and Cancel leaves the project as it was. */
export function PackageChecksDialog({
  open,
  onOpenChange,
  project,
  root,
  busy,
  onConfirm,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  project: string;
  root: string;
  busy: boolean;
  onConfirm: () => void;
}) {
  const [read, setRead] = useState<Read>(null);
  const [showFiles, setShowFiles] = useState(false);
  const [selected, setSelected] = useState<string | null>(null);
  const filesId = useId();

  useEffect(() => {
    if (!open) {
      setRead(null);
      setShowFiles(false);
      setSelected(null);
      return;
    }
    let live = true;
    void commands
      .packageCheckPlan({ scope: "project", root })
      .then((result) => {
        if (!live) return;
        setRead(
          result.status === "ok"
            ? { plan: result.data }
            : { failed: result.error },
        );
      });
    return () => {
      live = false;
    };
  }, [open, root]);

  const plan = read !== null && "plan" in read ? read.plan : null;
  const chosen =
    plan?.files.find((file) => file.path === selected) ??
    plan?.files[0] ??
    null;

  return (
    <ConfirmDialog
      open={open}
      onOpenChange={onOpenChange}
      title={enableChecksTitle(project)}
      description={PACKAGE_CHECKS_PURPOSE}
      confirmLabel={ENABLE_CHECKS_LABEL}
      wide={showFiles}
      busy={busy}
      // Nothing is offered over a plan that could not be read: the files
      // this would write are the whole of what is being agreed to.
      confirmDisabled={plan === null}
      confirmDisabledNote={
        read !== null && "failed" in read ? read.failed : PLAN_PENDING
      }
      onConfirm={onConfirm}
    >
      <div className="flex flex-col gap-3 text-[13px] text-muted-foreground">
        <p>{CHECKS_WHEN}</p>
        <p>{CHECKS_QUIET}</p>
        {/* Two separate facts, each drawn on its own evidence. An
            unsettled position holds up its own item; waiting changes hold
            up the registration. Drawing one instead of the other made the
            conflict sentence answer for both, and it cannot. */}
        {plan && plan.otherPending > 0 ? (
          <p>{otherChangesWaiting(plan.otherPending)}</p>
        ) : null}
        {plan && plan.conflicts.length > 0 ? (
          <div className="flex flex-col gap-1">
            <p>{CHECKS_CONFLICTS_NOTE}</p>
            <p className="font-medium text-foreground">{CONFLICTS_LABEL}</p>
            <ul className="list-disc pl-4">
              {plan.conflicts.map((detail) => (
                <li key={detail} className="font-mono text-xs">
                  {detail}
                </li>
              ))}
            </ul>
          </div>
        ) : null}
        {read === null ? <p>{PLAN_PENDING}</p> : null}
        {read !== null && "failed" in read ? (
          <p className="text-critical">
            {PLAN_FAILED} {read.failed}
          </p>
        ) : null}
        {plan ? (
          <>
            <Button
              variant="outline"
              size="sm"
              className="self-start"
              aria-expanded={showFiles}
              aria-controls={filesId}
              onClick={() => setShowFiles((was) => !was)}
            >
              {showFiles ? (
                <ChevronDown className="size-4" />
              ) : (
                <ChevronRight className="size-4" />
              )}
              {FILES_DISCLOSURE_LABEL} ({plan.files.length})
            </Button>
            <div id={filesId} hidden={!showFiles}>
              <FileBrowser
                entries={plan.files.map((file) => ({
                  path: file.path,
                  meta: (
                    <span className="text-[11px]">
                      {CHANGE_WORDS[file.change]}
                    </span>
                  ),
                }))}
                selected={chosen?.path ?? null}
                onSelect={setSelected}
                label={FILES_TREE_LABEL}
              >
                {chosen ? <PlannedFileView file={chosen} /> : null}
              </FileBrowser>
            </div>
          </>
        ) : null}
      </div>
    </ConfirmDialog>
  );
}

/** One planned file: what it is for, whether it is new, and its content
 *  where kendex holds it before the write — with the reason in its place
 *  where it does not, so no row is silently blank. */
function PlannedFileView({ file }: { file: PlannedFile }) {
  return (
    <div className="flex flex-col gap-2">
      <p className="text-[13px]">
        <span className="font-medium text-foreground">
          {ROLE_WORDS[file.role]}
        </span>
        {" · "}
        {CHANGE_WORDS[file.change]}
      </p>
      <p className="text-[13px] text-muted-foreground">
        {roleMeans(file.role, file.harness)}
      </p>
      {file.preview !== null ? (
        <FilePane path={file.path} content={file.preview} truncated={false} />
      ) : file.noPreview !== null ? (
        <p className="text-[13px] text-muted-foreground">
          {NO_PREVIEW_WORDS[file.noPreview]}
        </p>
      ) : null}
    </div>
  );
}
