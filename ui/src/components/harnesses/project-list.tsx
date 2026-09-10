import { MoreHorizontal } from "lucide-react";
import { useState } from "react";
import type { MissingProject, ProjectFlag, Scope } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { AddProjectDialog } from "@/components/harnesses/add-project-dialog";
import { FindProjectsDialog } from "@/components/harnesses/find-projects-dialog";
import { LocateFolderDialog } from "@/components/harnesses/locate-folder-dialog";
import { PlaceMarketplacesDialog } from "@/components/harnesses/place-marketplaces-dialog";
import { ProjectCard } from "@/components/harnesses/project-card";
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
import { ADD_PACKAGES_LABEL, addPackagesTo } from "@/lib/copy-install";
import { PLACE_MARKETPLACES_LABEL } from "@/lib/copy-model";
import {
  CHANGE_FOLDER_LABEL,
  missingBadge,
  REMOVE_FROM_LIST_BODY,
  REMOVE_FROM_LIST_LABEL,
  removeFromList,
  removeFromListTitle,
} from "@/lib/copy-project-move";
import {
  ADD_PROJECT_TITLE,
  FIND_PROJECTS_TITLE,
} from "@/lib/copy-project-setup";
import {
  type ItemPlace,
  installedCountByKind,
  selectionOf,
} from "@/lib/derive";
import { scopeNames } from "@/lib/labels";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import {
  packagesUncounted,
  usePackageIndex,
  usePackagesKnown,
  usePackagesRead,
} from "@/lib/package-identity";
import { pickFolder } from "@/lib/pick-folder";
import { everyPlace, sameScope } from "@/lib/scope";
import { sessionNoteState } from "@/lib/session-note";
import { availableUpdatesIn, outOfDateIn } from "@/lib/update-groups";
import { readUnsettled } from "@/lib/updates-read-state";
import { cn } from "@/lib/utils";
import { useAuditOnMount, useAuditStore } from "@/stores/audit";
import { useCommitOfferStore } from "@/stores/commit-offer";
import { useNavStore } from "@/stores/nav";
import { useProjectSetupStore } from "@/stores/project-setup";
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
  missing: MissingProject | undefined,
  flagged: ProjectFlag[],
):
  | { text: string; variant: "destructive" | "info"; title?: string }
  | undefined {
  if (missing)
    return { text: missingBadge(missing.why), variant: "destructive" };
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
  reachable,
  onAddPackages,
  onChangeFolder,
  onRemove,
}: {
  scope: Scope;
  /** What this place is called among the places drawn beside it, from
   *  [scopeNames] — the dialogs this menu opens name the place whose files
   *  they rewrite, and two projects can end in the same folder. */
  place: string;
  /** Whether this place can be written to at all. Everything that decides
   *  what a place installs writes that place's own files, so a folder
   *  kendex could not read is offered none of it: the browse would open on
   *  a place the install cannot reach, and the read behind the
   *  marketplaces it uses has nothing to read. What is left is the two
   *  actions about the entry itself. */
  reachable: boolean;
  /** Browse packages on this place's behalf. On the menu as well as in the
   *  empty state, because a place that already has packages is where more
   *  are usually wanted. */
  onAddPackages: () => void;
  /** Point this project at another folder. Offered whatever the recorded
   *  folder reads as: a folder that exists is not proof it is the project
   *  — something else can have been created at the path since. */
  onChangeFolder?: () => void;
  onRemove?: () => void;
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
          {reachable ? (
            <>
              <DropdownMenuItem onClick={onAddPackages}>
                {ADD_PACKAGES_LABEL}
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => setMarketplacesOpen(true)}>
                {PLACE_MARKETPLACES_LABEL}
              </DropdownMenuItem>
            </>
          ) : null}
          {onChangeFolder ? (
            <DropdownMenuItem onClick={onChangeFolder}>
              {CHANGE_FOLDER_LABEL}
            </DropdownMenuItem>
          ) : null}
          {onRemove ? (
            <DropdownMenuItem className="text-critical" onClick={onRemove}>
              {removeFromList(place)}
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
  const goToMarketplaces = useNavStore((s) => s.goToMarketplaces);
  // Which places are still being read after being added, and which of
  // those reads failed. Registration and this are separate answers — see
  // `stores/project-setup.ts`.
  const checking = useProjectSetupStore((s) => s.checking);
  const unchecked = useProjectSetupStore((s) => s.unchecked);
  const check = useProjectSetupStore((s) => s.check);
  // Browsing on a place's behalf: the Packages tab, told which place asked.
  // That is what makes "add a project, then add packages to it" one path —
  // the guided install opens on the project the reader came from.
  const addPackages = (scope: Scope) => goToMarketplaces("packages", scope);
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
  // A count is a fact worth drawing while a read runs; a write read off
  // those rows is not, and the store refuses one. The card's review holds
  // in the same words the Updates page uses rather than letting the click
  // answer with an error.
  const updatesHeld = useUpdatesStore(readUnsettled);
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
  // The project a folder is being picked for, with the folder the reader
  // already chose. Held here rather than in the card, so the chooser is
  // opened where the button was pressed and the dialog opens with an answer
  // to give rather than an errand to start.
  const [locating, setLocating] = useState<{
    root: string;
    name: string;
    picked: string;
  } | null>(null);
  const locate = (root: string, name: string) => {
    void pickFolder().then((picked) => {
      if (picked) setLocating({ root, name, picked });
    });
  };
  const [adding, setAdding] = useState(false);
  const [scanning, setScanning] = useState(false);

  // Projects where kendex owns changed files and no offer can be made: a
  // dialog that offers nothing is a modal a person has to dismiss for no
  // reason, so the state is flagged on the card instead.
  const flagged = useCommitOfferStore((s) => s.flagged);
  const items = result?.items ?? [];
  const packageOf = usePackageIndex();
  // The badges count packages and their clicks open the Library on the same
  // narrowing, so both wait on the one read that says which installations
  // are one package.
  const uncounted = packagesUncounted(usePackagesKnown(), usePackagesRead());
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
          <Button onClick={() => setAdding(true)}>{ADD_PROJECT_TITLE}</Button>
          <Button variant="outline" onClick={() => setScanning(true)}>
            {FIND_PROJECTS_TITLE}
          </Button>
        </div>

        <ProjectCard
          name="Personal"
          subtitle="Works in every project on this computer"
          counts={
            packageOf
              ? [...installedCountByKind(items, personal, packageOf).entries()]
              : []
          }
          uncounted={uncounted}
          emptyLabel="Nothing from kendex yet."
          onOpen={() => goToLibrary(personal)}
          onKindClick={(kind) => goToLibrary({ ...personal, kind })}
          unmanaged={notManaged(GLOBAL)}
          onUnmanaged={() => goToUnmanaged(GLOBAL)}
          outOfDate={outOfDate(GLOBAL)}
          onOutOfDate={() => setReviewing({ scope: GLOBAL, name: "Personal" })}
          onAddPackages={() => addPackages(GLOBAL)}
          addPackagesLabel={addPackagesTo("Personal")}
          action={
            <PlaceActions
              scope={GLOBAL}
              place="Personal"
              reachable
              onAddPackages={() => addPackages(GLOBAL)}
            />
          }
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
            // A folder the scan could not read as one. Everything the card
            // would otherwise say about this place is read out of that
            // folder, so the card says this instead.
            const missing = (result?.missingProjects ?? []).find(
              (one) => one.root === root,
            );
            return (
              <ProjectCard
                key={root}
                name={name}
                subtitle={root}
                path={root}
                counts={
                  packageOf
                    ? [
                        ...installedCountByKind(
                          items,
                          place,
                          packageOf,
                        ).entries(),
                      ]
                    : []
                }
                uncounted={uncounted}
                emptyLabel="Nothing from kendex yet."
                badge={badgeFor(root, missing, flagged)}
                onOpen={() => goToLibrary(place)}
                onKindClick={(kind) => goToLibrary({ ...place, kind })}
                unmanaged={notManaged(scope)}
                onUnmanaged={() => goToUnmanaged(scope)}
                outOfDate={outOfDate(scope)}
                onOutOfDate={() =>
                  setReviewing({ scope, name: namedAlone(root) })
                }
                checking={checking.includes(root)}
                checkFailed={unchecked.includes(root)}
                onRecheck={() => void check(root)}
                onAddPackages={() => addPackages(scope)}
                addPackagesLabel={addPackagesTo(namedAlone(root))}
                missing={
                  missing && {
                    why: missing.why,
                    onLocate: () => locate(root, namedAlone(root)),
                    onRecheck: () => void check(root),
                    onRemove: () => setRemoveTarget(root),
                  }
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
                    reachable={missing === undefined}
                    onAddPackages={() => addPackages(scope)}
                    onChangeFolder={() => locate(root, namedAlone(root))}
                    onRemove={() => setRemoveTarget(root)}
                  />
                }
              />
            );
          })
        )}

        <UpdateReviewDialog
          rows={
            reviewing ? availableUpdatesIn(updateRows, reviewing.scope) : []
          }
          // Every tracked place, so a review names this one the way the
          // card's own menu does when two roots end in the same folder.
          among={everyPlace(projects)}
          place={reviewing?.name ?? null}
          open={reviewing !== null}
          onOpenChange={(open) => {
            if (!open) setReviewing(null);
          }}
          busy={updatesBusy}
          held={updatesHeld}
          onConfirm={(rows) => {
            setReviewing(null);
            void useUpdatesStore.getState().updateRows(rows);
          }}
        />
        {locating ? (
          <LocateFolderDialog
            root={locating.root}
            name={locating.name}
            picked={locating.picked}
            onClose={() => setLocating(null)}
          />
        ) : null}
        <AddProjectDialog
          open={adding}
          onOpenChange={setAdding}
          registerProject={registerProject}
        />
        <FindProjectsDialog
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
          title={removeFromListTitle(
            removeTarget ? namedAlone(removeTarget) : "",
          )}
          description={REMOVE_FROM_LIST_BODY}
          confirmLabel={REMOVE_FROM_LIST_LABEL}
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
