import { MoreHorizontal } from "lucide-react";
import { useState } from "react";
import type { ProjectFlag, Scope } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { AddProjectDialog } from "@/components/harnesses/add-project-dialog";
import { PlaceMarketplacesDialog } from "@/components/harnesses/place-marketplaces-dialog";
import { ProjectCard } from "@/components/harnesses/project-card";
import { ScanFolderDialog } from "@/components/harnesses/scan-folder-dialog";
import { SessionNoteRow } from "@/components/harnesses/session-note-row";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { UpdateReviewDialog } from "@/components/updates/update-review-dialog";
import { unmanagedCount } from "@/lib/audit-counts";
import {
  NOT_CHECKED_BADGE,
  notChecked,
  uncommittedBadge,
  uncommittedInProgress,
  uncommittedNoBranch,
} from "@/lib/copy-commit-offer";
import { PLACE_MARKETPLACES_LABEL } from "@/lib/copy-model";
import {
  type ItemPlace,
  installedCountByKind,
  selectionOf,
} from "@/lib/derive";
import { scopeNames } from "@/lib/labels";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { everyPlace, sameScope } from "@/lib/scope";
import { sessionNoteState } from "@/lib/session-note";
import { outOfDateIn, visibleUpdates } from "@/lib/update-groups";
import { cn } from "@/lib/utils";
import { useAuditOnMount, useAuditStore } from "@/stores/audit";
import { useCommitOfferStore } from "@/stores/commit-offer";
import { useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import { useUpdatesStore } from "@/stores/updates";

const GLOBAL: Scope = { scope: "global" };

/** What the card flags beside the project's name. A missing folder is a
 *  fault and outranks everything; uncommitted files kendex wrote are not a
 *  fault, and their reason is on hover the way the card already hides a
 *  status word behind one. */
function badgeFor(
  root: string,
  missing: string[],
  flagged: ProjectFlag[],
):
  | { text: string; variant: "destructive" | "info"; title?: string }
  | undefined {
  if (missing.includes(root))
    return { text: "Folder not found", variant: "destructive" };
  const flag = flagged.find((each) => each.root === root);
  if (!flag) return undefined;
  switch (flag.reason.kind) {
    case "noBranch":
      return {
        text: uncommittedBadge(flag.count),
        variant: "info",
        title: uncommittedNoBranch(flag.count),
      };
    case "inProgress":
      return {
        text: uncommittedBadge(flag.count),
        variant: "info",
        title: uncommittedInProgress(flag.count, flag.reason.operation),
      };
    case "unreadable":
      return {
        text: NOT_CHECKED_BADGE,
        variant: "info",
        title: notChecked(flag.reason.said),
      };
  }
}

/** One place's own actions, on its card. Every setting that decides what
 *  this place installs is reached here — the marketplaces it installs from
 *  included — because that is what the reader came to this card to manage.
 *  Personal has no tracking to stop, so it gets the menu without it. */
function PlaceActions({
  scope,
  place,
  onStopTracking,
}: {
  scope: Scope;
  /** What this place is called among the places drawn beside it, from
   *  [scopeNames] — the dialogs this menu opens name the place whose files
   *  they rewrite, and two projects can end in the same folder. */
  place: string;
  onStopTracking?: () => void;
}) {
  const [marketplacesOpen, setMarketplacesOpen] = useState(false);
  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger
          render={
            <Button
              size="icon-sm"
              variant="ghost"
              aria-label={`More actions for ${place}`}
            >
              <MoreHorizontal className="size-4" />
            </Button>
          }
        />
        <DropdownMenuContent align="end">
          <DropdownMenuItem onClick={() => setMarketplacesOpen(true)}>
            {PLACE_MARKETPLACES_LABEL}
          </DropdownMenuItem>
          {onStopTracking ? (
            <DropdownMenuItem
              className="text-critical"
              onClick={onStopTracking}
            >
              Stop tracking {place}…
            </DropdownMenuItem>
          ) : null}
        </DropdownMenuContent>
      </DropdownMenu>
      <PlaceMarketplacesDialog
        open={marketplacesOpen}
        onOpenChange={setMarketplacesOpen}
        scope={scope}
        place={place}
      />
    </>
  );
}

/** "Projects": personal plus every registered project, one card each. */
export function ProjectList() {
  useAuditOnMount();
  const result = useScanStore((s) => s.result);
  const views = useAuditStore((s) => s.views);
  // The audit read's own outcome: a failed adopt is not a failed audit, and
  // says so through the problems dialog rather than this list.
  const auditFailure = useAuditStore((s) => s.read.error);
  const goToLibrary = useNavStore((s) => s.goToLibrary);
  const goToUnmanaged = useNavStore((s) => s.goToUnmanaged);
  // What kendex is not looking after at one place. This is the only surface
  // in the app that mentions it: a count on the card for the place it is
  // at, and the flow that offers to take it on behind the click.
  // Null where the place could not be read; zero where the audit simply has
  // not reached it yet, which says nothing and will resolve on its own.
  const notManaged = (scope: Scope): number | null =>
    unmanagedCount(
      views.find((v) => sameScope(v.scope, scope)),
      auditFailure,
    );
  // The start-of-session note's line, or nothing while no read can say.
  const noteRow = (root: string, name: string) => {
    const state = result
      ? sessionNoteState(
          result.items,
          views.find((v) => sameScope(v.scope, { scope: "project", root })),
          auditFailure,
          root,
        )
      : null;
    return state ? (
      <SessionNoteRow name={name} root={root} state={state} />
    ) : null;
  };
  const { settings, registerProject, unregisterProject, discoverProjects } =
    useSettingsStore();
  // What each place's own packages are standing on. Only a landed read puts
  // a number on a card, and a place the read could not cover at all has no
  // number to put: its rows are missing from these, and saying "0 out of
  // date" over that is the one thing a card must not do. Both are drawn as
  // nothing here, because Home and Problems carry the reason.
  const updateRows = useUpdatesStore((s) => s.rows);
  const updatesLanded = useUpdatesStore((s) => s.read.status === "landed");
  const unreadable = useUpdatesStore((s) => s.unreadable);
  const updatesBusy = useUpdatesStore((s) => s.busy);
  const updateRowsIn = (scope: Scope) =>
    visibleUpdates(updateRows).filter((row) => sameScope(row.scope, scope));
  const outOfDate = (scope: Scope): number | null =>
    updatesLanded && !unreadable.some((place) => sameScope(place.scope, scope))
      ? outOfDateIn(updateRows, scope)
      : null;
  // The place whose updates are being reviewed, with what it is called: one
  // dialog for every card, so the flow behind a card's line is the flow
  // behind the Updates page's own buttons.
  const [reviewing, setReviewing] = useState<{
    scope: Scope;
    name: string;
  } | null>(null);
  const [removeTarget, setRemoveTarget] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const [scanning, setScanning] = useState(false);

  // Projects where kendex owns changed files and no offer can be made: a
  // dialog that offers nothing is a modal a person has to dismiss for no
  // reason, so the state is flagged on the card instead.
  const flagged = useCommitOfferStore((s) => s.flagged);
  const items = result?.items ?? [];
  const projects = settings?.projects ?? [];
  // What a place is called where it is named ALONE, away from its card: a
  // card's menu opens dialogs that say which place's files an action
  // rewrites, and two roots ending in the same folder would name neither.
  // The card itself keeps its folder name, with the path right beneath it.
  // Personal leads, as [everyPlace] orders it, so a project's name sits at
  // its index plus one.
  const placeNames = scopeNames(everyPlace(projects));
  const namedAlone = (root: string): string =>
    placeNames[projects.indexOf(root) + 1] ?? root;
  // A card counts one place and links to that place. Both read the same
  // object, so the badge cannot name a narrowing its click does not make.
  const personal: ItemPlace = { scope: "global" };

  return (
    <div className={PAGE_BODY}>
      <div className={cn("flex flex-col gap-4", CONTENT_WIDTH)}>
        {/* Adding a project is a short errand, not part of reading the list
            — a form pinned under the cards would take more of the page than
            the projects themselves. */}
        <div className="flex justify-end gap-2">
          <Button onClick={() => setAdding(true)}>Add a project</Button>
          <Button variant="outline" onClick={() => setScanning(true)}>
            Scan a folder
          </Button>
        </div>

        <ProjectCard
          name="Personal"
          subtitle="Works in every project on this computer"
          counts={[...installedCountByKind(items, personal).entries()]}
          emptyLabel="Nothing from kendex yet."
          onOpen={() => goToLibrary(personal)}
          onKindClick={(kind) => goToLibrary({ ...personal, kind })}
          unmanaged={notManaged(GLOBAL)}
          onUnmanaged={() => goToUnmanaged(GLOBAL)}
          outOfDate={outOfDate(GLOBAL)}
          onOutOfDate={() => setReviewing({ scope: GLOBAL, name: "Personal" })}
          action={<PlaceActions scope={GLOBAL} place="Personal" />}
        />

        {projects.length === 0 ? (
          <p className="py-2 text-sm text-muted-foreground">
            No projects yet — add one to manage its tools.
          </p>
        ) : (
          projects.map((root) => {
            const name = root.split("/").pop() ?? root;
            const scope: Scope = { scope: "project", root };
            const place: ItemPlace = { scope: selectionOf(scope) };
            return (
              <ProjectCard
                key={root}
                name={name}
                subtitle={root}
                path={root}
                counts={[...installedCountByKind(items, place).entries()]}
                emptyLabel="Nothing from kendex yet."
                badge={badgeFor(root, result?.missingProjects ?? [], flagged)}
                onOpen={() => goToLibrary(place)}
                onKindClick={(kind) => goToLibrary({ ...place, kind })}
                unmanaged={notManaged(scope)}
                onUnmanaged={() => goToUnmanaged(scope)}
                outOfDate={outOfDate(scope)}
                onOutOfDate={() =>
                  setReviewing({ scope, name: namedAlone(root) })
                }
                // Not drawn until the scan and the audit have answered for
                // this place: a card saying the note is off before either
                // was read would be claiming a state the app has not
                // checked.
                note={noteRow(root, name)}
                action={
                  <PlaceActions
                    scope={scope}
                    place={namedAlone(root)}
                    onStopTracking={() => setRemoveTarget(root)}
                  />
                }
              />
            );
          })
        )}

        <UpdateReviewDialog
          rows={reviewing ? updateRowsIn(reviewing.scope) : []}
          place={reviewing?.name ?? null}
          open={reviewing !== null}
          onOpenChange={(open) => {
            if (!open) setReviewing(null);
          }}
          busy={updatesBusy}
          onConfirm={(rows) => {
            setReviewing(null);
            void useUpdatesStore.getState().updateRows(rows);
          }}
        />
        <AddProjectDialog
          open={adding}
          onOpenChange={setAdding}
          registerProject={registerProject}
        />
        <ScanFolderDialog
          open={scanning}
          onOpenChange={setScanning}
          projects={projects}
          registerProject={registerProject}
          discoverProjects={discoverProjects}
        />
        <ConfirmDialog
          open={removeTarget !== null}
          onOpenChange={(open) => {
            if (!open) setRemoveTarget(null);
          }}
          title={`Stop tracking ${removeTarget ? namedAlone(removeTarget) : ""}?`}
          description="kendex will stop managing this project. Nothing in the folder is deleted."
          confirmLabel="Stop tracking"
          destructive
          onConfirm={() => {
            if (removeTarget) void unregisterProject(removeTarget);
            setRemoveTarget(null);
          }}
        />
      </div>
    </div>
  );
}
