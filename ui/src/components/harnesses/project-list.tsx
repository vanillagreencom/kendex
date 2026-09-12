import { MoreHorizontal } from "lucide-react";
import { useEffect, useState } from "react";
import type { ChangesState, ItemKind, MissingProject, Scope } from "@/bindings";
import { PACKAGE_CHECK_HARNESSES } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { AddProjectDialog } from "@/components/harnesses/add-project-dialog";
import { FindProjectsDialog } from "@/components/harnesses/find-projects-dialog";
import { LocateFolderDialog } from "@/components/harnesses/locate-folder-dialog";
import { PackageChecksRow } from "@/components/harnesses/package-checks-row";
import { PlaceMarketplacesDialog } from "@/components/harnesses/place-marketplaces-dialog";
import { ProjectCard } from "@/components/harnesses/project-card";
import { ChangesLine } from "@/components/project-changes/changes-line";
import { CreateTemplateDialog } from "@/components/templates/create-template-dialog";
import { InstallTemplateDialog } from "@/components/templates/install-template-dialog";
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
import { lastCouldCheck } from "@/lib/copy-project-changes";
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
  CREATE_FROM_PROJECT_LABEL,
  INSTALL_TEMPLATE_LABEL,
} from "@/lib/copy-templates";
import {
  type ItemPlace,
  installedCountByKind,
  selectionOf,
} from "@/lib/derive";
import { scopeNames } from "@/lib/labels";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { useCountableMissingRows } from "@/lib/missing-files";
import { checksStanding } from "@/lib/package-checks";
import {
  packagesUncounted,
  uncountedRead,
  useOriginIndex,
  usePackageIndex,
  usePackagesKnown,
  usePackagesRead,
} from "@/lib/package-identity";
import { pickFolder } from "@/lib/pick-folder";
import { placeIsReachable } from "@/lib/reachable-projects";
import { everyPlace, sameScope } from "@/lib/scope";
import { availableUpdatesIn, outOfDateIn } from "@/lib/update-groups";
import { readUnsettled, rowsCountable } from "@/lib/updates-read-state";
import { cn } from "@/lib/utils";
import { useAuditOnMount, useAuditStore } from "@/stores/audit";
import { useNavStore } from "@/stores/nav";
import {
  changesFor,
  type Sureness,
  surenessOf,
  useProjectChangesStore,
} from "@/stores/project-changes";
import { useProjectSetupStore } from "@/stores/project-setup";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import { useUpdatesStore } from "@/stores/updates";

const GLOBAL: Scope = { scope: "global" };

/** What the card flags beside the project's name. A missing folder is a
 *  fault and outranks everything; a checkout kendex cannot commit in is not
 *  a fault, and its reason is on hover the way the card already hides a
 *  status word behind one.
 *
 *  The second half is read from the passive project-changes row, which is
 *  the one answer about what a project holds and what state it is in. The
 *  ordinary case — files waiting on a branch a commit could land on —
 *  carries no badge at all: the card's own Review changes line says it in
 *  words, and a badge over it would be the same fact twice. */
function badgeFor(
  missing: MissingProject | undefined,
  state: ChangesState | null,
  /** How sure the read is about this project. All four states reach here,
   *  because the card is where a person decides whether to look: `waiting`
   *  carries no badge (the answer is coming), `unknown` says so whatever
   *  produced it — a project the read skipped or one whose own read
   *  refused — and `stale` marks a row a failed read could not confirm. */
  sureness: Sureness,
):
  | { text: string; variant: "destructive" | "info"; title?: string }
  | undefined {
  if (missing)
    return { text: missingBadge(missing.why), variant: "destructive" };
  if (sureness === "waiting") return undefined;
  if (sureness === "unknown")
    return {
      text: NOT_CHECKED_BADGE,
      variant: "info",
      title: notChecked(
        state !== null && state.kind === "unreadable" ? state.said : [],
      ),
    };
  if (sureness === "stale")
    return {
      text: NOT_CHECKED_BADGE,
      variant: "info",
      title: lastCouldCheck(),
    };
  if (state === null) return undefined;
  switch (state.kind) {
    case "clean":
      return undefined;
    // `unknown` above already answered this one.
    case "unreadable":
      return undefined;
    case "pending": {
      const count = state.files.length;
      if (state.operation !== null)
        return {
          text: uncommittedBadge(count),
          variant: "info",
          title: uncommittedInProgress(count, state.operation),
        };
      return state.branch === null
        ? {
            text: uncommittedBadge(count),
            variant: "info",
            title: uncommittedNoBranch(count),
          }
        : undefined;
    }
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
  const [creatingTemplate, setCreatingTemplate] = useState(false);
  const [installingTemplate, setInstallingTemplate] = useState(false);
  // A template is made from a project's packages, and the personal setup
  // is not a project: the offer is on the cards it can act on.
  const root = scope.scope === "project" ? scope.root : null;
  // A folder can stop being readable while one of these dialogs stands
  // open — a rescan on focus, a disk unmounted, the folder renamed from a
  // terminal. Their controls write this place's own manifest or read its
  // own files, which is exactly what the menu behind them withholds once
  // the place cannot be read; leaving one open leaves those reads and
  // writes reachable, and one of them would seed a manifest and recreate
  // the folder that went away. So they go when the place does, on the
  // same one bit.
  useEffect(() => {
    if (reachable) return;
    setMarketplacesOpen(false);
    setInstallingTemplate(false);
    setCreatingTemplate(false);
  }, [reachable]);
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
              <DropdownMenuItem onClick={() => setInstallingTemplate(true)}>
                {INSTALL_TEMPLATE_LABEL}
              </DropdownMenuItem>
              {root ? (
                <DropdownMenuItem onClick={() => setCreatingTemplate(true)}>
                  {CREATE_FROM_PROJECT_LABEL}
                </DropdownMenuItem>
              ) : null}
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
      <InstallTemplateDialog
        into={scope}
        open={installingTemplate}
        onOpenChange={setInstallingTemplate}
      />
      {root ? (
        <CreateTemplateDialog
          project={root}
          place={place}
          open={creatingTemplate}
          onOpenChange={setCreatingTemplate}
        />
      ) : null}
    </>
  );
}

/** "Projects": personal plus every registered project, one card each. */
export function ProjectList() {
  useAuditOnMount();
  const result = useScanStore((s) => s.result);
  // Whether the last scan landed. `stores/scan.ts` keeps the previous
  // result through a failure on purpose, so a reader that takes `result`
  // for this pass's observations is reading a read that did not happen.
  const scanFailure = useScanStore((s) => s.error);
  // Which source each observed installation came from. A hook wearing the
  // check's name is only the check where the record says it is kendex's
  // own, and the checks line reads this rather than the name.
  const originOf = useOriginIndex();
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
  // The project the registry recorded most recently, and the way to say
  // the offer about it has been answered.
  const justAdded = useProjectSetupStore((s) => s.justAdded);
  const clearJustAdded = useProjectSetupStore((s) => s.clearJustAdded);
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
  // The lines under a project's counts: what kendex has waiting for a
  // commit here, and where its package checks stand. Both are about the
  // place rather than about what is installed, which is why they sit
  // together below the counts.
  //
  // Drawn only for a place whose folder was read. A card over a folder
  // nothing was read from draws no note at all — it is replaced by what
  // could not be read and the ways out of it, which is the card's own
  // state and neither of these lines'.
  const noteRow = (root: string, name: string, place: ItemPlace) => {
    // What the scan observed this pass, which a failed scan is none of.
    const observations = scanFailure === null ? result : null;
    return (
      <>
        <div className="px-4">
          <ChangesLine root={root} />
        </div>
        <PackageChecksRow
          name={name}
          root={root}
          harnesses={PACKAGE_CHECK_HARNESSES}
          standing={checksStanding(
            observations?.items ?? [],
            views.find((v) => sameScope(v.scope, { scope: "project", root })),
            auditFailure,
            root,
            observations ? PACKAGE_CHECK_HARNESSES : null,
            originOf,
          )}
          onOpenLibrary={() => goToLibrary({ ...place, kind: "hook" })}
        />
      </>
    );
  };
  const { settings, registerProject, unregisterProject, discoverProjects } =
    useSettingsStore();
  // What each place's own packages are standing on. Only a landed read puts
  // a number on a card, and a place the read could not cover at all has no
  // number to put: its rows are missing from these, and saying "0 out of
  // date" over that is the one thing a card must not do. Both are drawn as
  // nothing here, because Home and Problems carry the reason.
  const updateRows = useUpdatesStore((s) => s.rows);
  const updatesRead = useUpdatesStore((s) => s.read);
  const updatesCountable = useUpdatesStore(rowsCountable);
  const unreadable = useUpdatesStore((s) => s.unreadable);
  const updatesBusy = useUpdatesStore((s) => s.busy);
  // A count is a fact worth drawing while a read runs; a write read off
  // those rows is not, and the store refuses one. The card's review holds
  // in the same words the Updates page uses rather than letting the click
  // answer with an error.
  const updatesHeld = useUpdatesStore(readUnsettled);
  const outOfDate = (scope: Scope): number | null =>
    updatesCountable &&
    !unreadable.some((place) => sameScope(place.scope, scope))
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

  // What each project has waiting for a commit, from the one passive read.
  // The card draws two things from it: the quiet Review changes line, and
  // the badge for a checkout no commit could land in.
  const changes = useProjectChangesStore((s) => s.rows);
  // Both halves of that read, selected as the store holds them. A selector
  // returning a function built here would mint a new reference on every
  // render and never settle, so the per-project answer is worked out below
  // from these instead.
  const changesRead = useProjectChangesStore((s) => s.read);
  const items = result?.items ?? [];
  const packageOf = usePackageIndex();
  // The badges count packages and their clicks open the Library on the same
  // narrowing, so both wait on the one read that says which installations
  // are one package.
  const uncounted = packagesUncounted(usePackagesKnown(), usePackagesRead());
  // A place's total holds the packages whose rendering is gone — the record
  // says they are installed here — so the badges count them, and a check
  // that could not confirm them takes the badges away rather than publishing
  // a number short by exactly those. `installedCountByKind` is what weighs
  // the two, because only it knows whether this narrowing admits such a row.
  const countableMissing = useCountableMissingRows();
  // What one place holds, by kind — null where no number may be taken. Both
  // cards below ask the same way, so Personal and a project cannot count a
  // package one of them admits and the other does not.
  const countsAt = (place: ItemPlace): Map<ItemKind, number> | null =>
    packageOf
      ? installedCountByKind(items, place, packageOf, countableMissing)
      : null;
  // What a place's badges say instead of a number: the join's own reason
  // where it has one, and the update check that could not confirm the rows
  // otherwise. One string, because a card has one slot for it and the
  // counts are gone either way.
  const uncountedHere = (counts: Map<ItemKind, number> | null): string | null =>
    uncounted ?? (counts === null ? uncountedRead(updatesRead) : null);
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
  const personalCounts = countsAt(personal);

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
          counts={personalCounts ? [...personalCounts.entries()] : []}
          uncounted={uncountedHere(personalCounts)}
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
            // Whether anything may be written here. Not the inverse of the
            // line above: a scan that has not answered names no missing
            // folder and has found none either, and an offer to install
            // under a path nobody has looked at is the same claim made
            // from silence. One judge, shared with the guided install.
            const reachable = placeIsReachable(root, result);
            const counts = countsAt(place);
            return (
              <ProjectCard
                key={root}
                name={name}
                subtitle={root}
                path={root}
                counts={counts ? [...counts.entries()] : []}
                uncounted={uncountedHere(counts)}
                emptyLabel="Nothing from kendex yet."
                badge={badgeFor(
                  missing,
                  changesFor(changes, root)?.state ?? null,
                  surenessOf({ rows: changes, read: changesRead }, root),
                )}
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
                onAddPackages={reachable ? () => addPackages(scope) : undefined}
                addPackagesLabel={
                  reachable ? addPackagesTo(namedAlone(root)) : undefined
                }
                missing={
                  missing && {
                    why: missing.why,
                    onLocate: () => locate(root, namedAlone(root)),
                    onRecheck: () => void check(root),
                    onRemove: () => setRemoveTarget(root),
                  }
                }
                note={noteRow(root, name, place)}
                action={
                  <PlaceActions
                    scope={scope}
                    place={namedAlone(root)}
                    reachable={reachable}
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
        {/* Adding a project and filling it are one path: the folder is
            registered, and the offer to install a saved selection into it
            follows straight away. The root is the one the registry
            recorded, not the string that was typed. */}
        {justAdded ? (
          <InstallTemplateDialog
            into={{ scope: "project", root: justAdded }}
            open
            onOpenChange={(open) => {
              if (!open) clearJustAdded();
            }}
          />
        ) : null}
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
