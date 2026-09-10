import type { ReactNode } from "react";
import { useState } from "react";
import { toast } from "sonner";
import type { ChangesState, ProjectFlag } from "@/bindings";
import { PageHeader } from "@/components/page-header";
import { pathEntries } from "@/components/project-changes/change-rows";
import { ChangedFiles } from "@/components/project-changes/changed-files";
import { RevertDialog } from "@/components/project-changes/revert-dialog";
import { Section } from "@/components/section";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  capitalised,
  notChecked,
  OTHER_LABEL,
  otherNote,
  SHARED_LABEL,
  SHARED_NOTE,
  uncommittedInProgress,
  uncommittedNoBranch,
} from "@/lib/copy-commit-offer";
import {
  BRANCH_LABEL,
  CHANGED_FILES_SECTION,
  CHANGES_GONE_NOTE,
  CHANGES_UNAVAILABLE_TITLE,
  COMMIT_CHANGES_LABEL,
  COULD_NOT_CHECK,
  EDITED_PACKAGES_LABEL,
  FOLDER_LABEL,
  inProgressHeld,
  inProgressValue,
  NO_BRANCH_HELD,
  NO_BRANCH_VALUE,
  NOT_APPLICABLE,
  NOTHING_PENDING,
  PACKAGE_EDITS_LABEL,
  PACKAGE_EDITS_NOTE,
  PACKAGE_EDITS_ROUTES,
  PROJECT_CHANGES_STANDING,
  projectChangesTitle,
  REVERT_ALL_LABEL,
  REVERT_LABEL,
  revertedToast,
  revertOneLabel,
  UNREADABLE_HELD,
  WHERE_SECTION,
} from "@/lib/copy-project-changes";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { rescanEverything, trackedProjects } from "@/lib/rescan";
import { cn } from "@/lib/utils";
import { useCommitOfferStore } from "@/stores/commit-offer";
import { useNavStore } from "@/stores/nav";
import {
  changesFor,
  pendingPaths,
  useProjectChangesStore,
} from "@/stores/project-changes";

/** One project's pending kendex changes, in one place.
 *
 *  Reached from the project's card and from the project's own view. It is
 *  the answer to "what changed, why did kendex ask, and does a commit
 *  include work I left earlier" — and it is where deferred work lives once
 *  a person has dismissed the offer, so nothing has to chase them about it.
 *
 *  It never opens itself. Everything on it is drawn from the passive read
 *  every refresh already makes, and the commit is a button: a person who
 *  turned the offer off still gets this page, because that setting decides
 *  whether kendex asks a question, not whether they may see their own
 *  project.
 *
 *  The states a commit cannot be made in — no branch, a git operation part
 *  way through, a read that would not run — stay on this page with their
 *  changes on screen and the reason beside the button. Nothing is hidden
 *  and no selection is reset. */
export function ProjectChangesPage() {
  const root = useNavStore((s) => s.changesRoot);
  const goToLibrary = useNavStore((s) => s.goToLibrary);
  const rows = useProjectChangesStore((s) => s.rows);
  const read = useProjectChangesStore((s) => s.read);
  const openFor = useCommitOfferStore((s) => s.openFor);
  // Which file the viewer has open, so Put files back can be about the one
  // in front of the reader as well as about the whole set.
  const [open, setOpen] = useState<string | null>(null);
  const [reverting, setReverting] = useState<string[] | null>(null);
  const [unavailable, setUnavailable] = useState<string | null>(null);

  // No project named is no page: every way in names one, so this is a
  // navigation that never happened rather than a state to design for.
  if (!root) return null;
  const name = root.split("/").pop() ?? root;
  const row = changesFor(rows, root);
  const paths = pendingPaths(row);
  const state = row?.state ?? null;

  const commit = async () => {
    const answer = await openFor(root);
    if (answer.at === "offer") return;
    // Every other answer says something. A read that would not run says
    // what it said, a project with nothing left says that, and a state no
    // commit can be made in says which state — from the read that refused,
    // not from the row this page drew before it.
    setUnavailable(
      answer.at === "failed"
        ? answer.error
        : answer.at === "nothing"
          ? CHANGES_GONE_NOTE
          : blockedReason(answer.flag),
    );
  };

  return (
    <div>
      <PageHeader
        title={projectChangesTitle(name)}
        subtitle={PROJECT_CHANGES_STANDING}
      />
      <div className={PAGE_BODY}>
        <div className={cn("flex flex-col gap-6", CONTENT_WIDTH)}>
          <Section title={WHERE_SECTION}>
            <dl className="space-y-1 text-sm">
              <Row label={FOLDER_LABEL}>
                <span className="font-mono text-xs">{root}</span>
              </Row>
              <Row label={BRANCH_LABEL}>{branchValue(state)}</Row>
            </dl>
          </Section>

          {/* The read itself failed and left nothing behind. Not zero
              changes: nothing is known about this project, so the page says
              so and offers the read again. */}
          {row === null ? (
            <StatusNote
              tone="warning"
              title={COULD_NOT_CHECK}
              action={
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => void rescanEverything({ announce: true })}
                >
                  {TRY_AGAIN_LABEL}
                </Button>
              }
            >
              {read.error}
            </StatusNote>
          ) : state?.kind === "unreadable" ? (
            <StatusNote
              tone="warning"
              title={COULD_NOT_CHECK}
              action={
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => void rescanEverything({ announce: true })}
                >
                  {TRY_AGAIN_LABEL}
                </Button>
              }
            >
              <pre className="overflow-auto whitespace-pre-wrap break-all font-mono text-xs">
                {state.said.join("\n")}
              </pre>
            </StatusNote>
          ) : paths.length === 0 ? (
            <p className="text-sm text-muted-foreground">{NOTHING_PENDING}</p>
          ) : (
            <>
              <Section title={CHANGED_FILES_SECTION}>
                <ChangedFiles
                  root={root}
                  entries={pathEntries(paths)}
                  onOpen={setOpen}
                />
              </Section>

              {state?.kind === "pending" && state.shared.length > 0 ? (
                <Section title={SHARED_LABEL} description={SHARED_NOTE}>
                  <Paths paths={state.shared} />
                </Section>
              ) : null}

              {state?.kind === "pending" && state.others > 0 ? (
                <Section title={OTHER_LABEL}>
                  <p className="text-[13px] text-muted-foreground">
                    {otherNote(state.others)}
                  </p>
                </Section>
              ) : null}

              <div className="flex flex-wrap items-center gap-2">
                <Button
                  disabled={heldReason(state) !== null}
                  title={heldReason(state) ?? undefined}
                  onClick={() => void commit()}
                >
                  {COMMIT_CHANGES_LABEL}
                </Button>
                <Button
                  variant="outline"
                  onClick={() => setReverting(open ? [open] : paths)}
                >
                  {REVERT_LABEL}
                </Button>
                <span className="text-[13px] text-muted-foreground">
                  {open ? revertOneLabel(open) : REVERT_ALL_LABEL}
                </span>
              </div>
              {heldReason(state) ? (
                <p className="text-[13px] text-muted-foreground">
                  {heldReason(state)}
                </p>
              ) : null}
              {unavailable ? (
                <StatusNote
                  tone="warning"
                  title={CHANGES_UNAVAILABLE_TITLE}
                  action={
                    <Button
                      size="sm"
                      variant="outline"
                      onClick={() => {
                        setUnavailable(null);
                        void commit();
                      }}
                    >
                      {TRY_AGAIN_LABEL}
                    </Button>
                  }
                >
                  {unavailable}
                </StatusNote>
              ) : null}

              <Section
                title={PACKAGE_EDITS_LABEL}
                description={PACKAGE_EDITS_NOTE}
              >
                <p className="max-w-prose text-[13px] text-muted-foreground">
                  {PACKAGE_EDITS_ROUTES}
                </p>
                <div className="mt-2">
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() =>
                      goToLibrary({
                        scope: { project: root },
                        edited: true,
                      })
                    }
                  >
                    {EDITED_PACKAGES_LABEL}
                  </Button>
                </div>
              </Section>
            </>
          )}
        </div>
      </div>

      <RevertDialog
        open={reverting !== null}
        onOpenChange={(next) => {
          if (!next) setReverting(null);
        }}
        root={root}
        paths={reverting ?? []}
        onDone={(effect) => {
          toast.success(
            revertedToast(effect.restored.length, effect.removed.length),
          );
          // The files moved, so every read that answers for them is asked
          // again — this page's own row among them, on `rescan.ts`'s rule.
          void rescanEverything();
          void useProjectChangesStore.getState().refresh(trackedProjects());
        }}
      />
    </div>
  );
}

/** What the branch row says, including the two states a commit cannot be
 *  made in. */
function branchValue(state: ChangesState | null): string {
  if (state === null || state.kind !== "pending") return NOT_APPLICABLE;
  if (state.operation !== null) return inProgressValue(state.operation);
  return state.branch ?? NO_BRANCH_VALUE;
}

/** Why the read that refused says no commit can be made here. The same
 *  words the project card carries on hover, from the same three states. */
function blockedReason(flag: ProjectFlag): string {
  switch (flag.reason.kind) {
    case "noBranch":
      return uncommittedNoBranch(flag.count);
    case "inProgress":
      return uncommittedInProgress(flag.count, flag.reason.operation);
    case "unreadable":
      return notChecked(flag.reason.said);
  }
}

/** Why a commit is not on offer here, or null where it is. */
function heldReason(state: ChangesState | null): string | null {
  if (state === null) return UNREADABLE_HELD;
  switch (state.kind) {
    case "unreadable":
      return UNREADABLE_HELD;
    case "clean":
      return null;
    case "pending":
      if (state.operation !== null)
        return inProgressHeld(capitalised(state.operation));
      return state.branch === null ? NO_BRANCH_HELD : null;
  }
}

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="text-muted-foreground">{label}</dt>
      <dd className="min-w-0 break-all text-right">{children}</dd>
    </div>
  );
}

/** Paths named and not opened: the shared configuration files kendex writes
 *  one key in, which it leaves to the person. Printed whole — an
 *  abbreviation guesses at a directory and names a different file. */
function Paths({ paths }: { paths: string[] }) {
  return (
    <ul className="max-h-40 overflow-y-auto font-mono text-xs text-muted-foreground">
      {paths.map((path) => (
        <li key={path} className="break-all">
          {path}
        </li>
      ))}
    </ul>
  );
}
