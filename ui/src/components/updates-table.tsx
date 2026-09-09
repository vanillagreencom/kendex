import { ChevronDown, ChevronRight } from "lucide-react";
import { useId, useState } from "react";
import type { Scope, UpdateRow } from "@/bindings";
import {
  InstalledScore,
  useInstalledReading,
} from "@/components/installed-score";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Table, TableBody, TableCell, TableRow } from "@/components/ui/table";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { PlaceCells } from "@/components/update-place-cells";
import { UpdatesTableHeader } from "@/components/updates-table-header";
import { EDITED_UPDATE_TAG, REMOVED_UPSTREAM_TAG } from "@/lib/copy";
import {
  EDITED_TAG_HELP,
  placesLabel,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATE_PACKAGE_EVERYWHERE_LABEL,
} from "@/lib/copy-updates";
import { selectionOf } from "@/lib/derive";
import { kindIcon } from "@/lib/kind-icon";
import { kindLabel, packageDisplayName } from "@/lib/labels";
import { opensLabel, opensOnActivate } from "@/lib/opens-on-activate";
import { sameScope } from "@/lib/scope";
import {
  groupKey,
  groupUpdates,
  placeKey,
  placeName,
  type UpdateGroup,
  updatablePlaces,
} from "@/lib/update-groups";
import { readUnsettled } from "@/lib/updates-read-state";
import { useNavStore } from "@/stores/nav";
import type { PackageView } from "@/stores/nav-types";
import { useUpdatesStore } from "@/stores/updates";
import { useUpdatesView } from "@/stores/updates-view";

/** Pending updates, one row per package. A package out of date in one
 *  place carries that place's controls on its row; one out of date in
 *  several expands into a row per place, each with its own controls.
 *  Callers render nothing for an empty list — a header over no rows would
 *  promise content that is not there. */
export function UpdatesTable({
  rows,
  onIgnore,
  onShowVersion,
  onUpdate,
}: {
  rows: UpdateRow[];
  /** Absent for muted rows: their only extra action is "notify again". */
  onIgnore?: (row: UpdateRow) => void;
  /** Present on the table that carries the `…` menu showing the Version
   *  column; the column itself follows the page-wide choice. */
  onShowVersion?: (show: boolean) => void;
  /** Open the one update flow over these rows, with the places they are
   *  named against — a package's own places, so the confirm that writes
   *  files tells two same-named folders apart the way its row does. */
  onUpdate?: (rows: UpdateRow[], place: string | null, among: Scope[]) => void;
}) {
  return (
    <Table>
      <UpdatesTableHeader onShowVersion={onShowVersion} />
      <TableBody>
        {groupUpdates(rows).map((group) => (
          <PackageRows
            key={groupKey(group)}
            group={group}
            onIgnore={onIgnore}
            onUpdate={onUpdate}
          />
        ))}
      </TableBody>
    </Table>
  );
}

/** One package's row, and its place rows once opened. */
export function PackageRows({
  group,
  onIgnore,
  onUpdate,
  defaultOpen = false,
}: {
  group: UpdateGroup;
  onIgnore?: (row: UpdateRow) => void;
  onUpdate?: (rows: UpdateRow[], place: string | null, among: Scope[]) => void;
  defaultOpen?: boolean;
}) {
  const [open, setOpen] = useState(defaultOpen);
  const placesId = useId();
  const busy = useUpdatesStore((s) => s.busy);
  const goToPackage = useNavStore((s) => s.goToPackage);
  const goToLibrary = useNavStore((s) => s.goToLibrary);
  const places = group.places;
  // Not loaded, mid-check and mid-load hold the package's own update
  // alike: either way these are not the rows an update would act on.
  const unconfirmed = useUpdatesStore(readUnsettled);
  const showVersion = useUpdatesView((s) => s.showVersion);
  const Icon = kindIcon(group.kind);
  const name = packageDisplayName(group);
  const scopes = places.map((place) => place.scope);
  const only = places.length === 1 ? places[0] : null;
  // The reading for this package at this row's places — not every copy of
  // the name on the machine, which would score a package the row is not
  // about.
  const reading = useInstalledReading(group.kind, group.name, scopes);
  const Chevron = open ? ChevronDown : ChevronRight;
  const tags = [
    places.some((p) => p.blockedByLocalEdit) ? EDITED_UPDATE_TAG : null,
    places.some((p) => p.removedUpstream) ? REMOVED_UPSTREAM_TAG : null,
  ].filter((tag) => tag !== null);
  // One package can be installed in several places, and the package page
  // shows one of them. The row's first place is the one its name opens.
  const first = places[0];
  // Which place the score is showing the state of, which is where it opens.
  // With a reading, that is the copy that earned it — over several places
  // the disc shows the worst of them, so opening the row's first place
  // would send a reader who clicked a warning to a copy carrying none of
  // the findings the number stood for. With no reading and a place whose
  // own read failed, the disc is showing that failure, and the place it
  // failed at is the only one where it can be read. An audit that failed as
  // a whole names no place, and leaves the row's first.
  const at = reading.result?.scope ?? reading.failedAt;
  const scored =
    (at && places.find((place) => sameScope(place.scope, at))) ?? first;
  /** This package's page, at one of the places this row is about. */
  const openPackage = (place: UpdateRow | undefined, view?: PackageView) => {
    if (!place) return;
    goToPackage(
      { kind: group.kind, name: group.name, scope: place.scope },
      view,
    );
  };

  return (
    <>
      {/* The package's own row opens the package, for the pointer and the
          keyboard alike. Its place rows below name places rather than this
          package, and open those instead. */}
      <TableRow
        {...opensOnActivate(() => openPackage(first), opensLabel(name))}
        className="cursor-pointer"
      >
        <TableCell>
          <div className="flex min-w-0 items-center gap-2.5">
            <Icon className="size-4 shrink-0 text-muted-foreground" />
            {/* What the copy on disk scored. It reads as part of the
                package's identity rather than a column of its own: a
                column would be one more thing to size on a table that
                already has to fit the default window. A score names a
                reading, so it opens that reading — the package page's
                Safety tab, where the findings already live. */}
            <InstalledScore
              reading={reading}
              onOpen={() => openPackage(scored, { mode: "safety" })}
            />
            {/* The name opens the package, on the rule the app follows
                everywhere: a row, card or chip naming a thing opens it. */}
            <button
              type="button"
              className="min-w-0 truncate text-left font-medium hover:underline"
              onClick={() => openPackage(first)}
            >
              {name}
            </button>
            {tags.map((tag) =>
              tag === EDITED_UPDATE_TAG ? (
                // What editing means for updates, where a keyboard and a
                // screen reader reach it, and on hover for a pointer.
                <Tooltip key={tag}>
                  <TooltipTrigger
                    render={
                      <Badge variant="outline" tabIndex={0}>
                        {tag}
                        <span className="sr-only">{EDITED_TAG_HELP}</span>
                      </Badge>
                    }
                  />
                  <TooltipContent className="max-w-72">
                    {EDITED_TAG_HELP}
                  </TooltipContent>
                </Tooltip>
              ) : (
                <Badge key={tag} variant="outline">
                  {tag}
                </Badge>
              ),
            )}
          </div>
        </TableCell>
        <TableCell className="text-muted-foreground">
          {kindLabel(group.kind)}
        </TableCell>
        {only ? (
          <PlaceCells
            row={only}
            among={scopes}
            onIgnore={onIgnore}
            onUpdate={
              onUpdate ? (one) => onUpdate([one], null, scopes) : undefined
            }
          />
        ) : (
          <>
            <TableCell>
              <Button
                size="sm"
                variant="ghost"
                className="-ml-2.5 text-muted-foreground"
                aria-expanded={open}
                aria-controls={placesId}
                onClick={() => setOpen((value) => !value)}
              >
                <Chevron className="size-3.5" />
                {placesLabel(places.length)}
              </Button>
            </TableCell>
            {showVersion ? <TableCell /> : null}
            <TableCell className="text-right">
              {/* Muted places only offer "notify again", so there is
                  nothing for a package-wide update to do. */}
              {onUpdate ? (
                <Button
                  size="sm"
                  variant="outline"
                  disabled={
                    busy || unconfirmed || updatablePlaces(places).length === 0
                  }
                  title={unconfirmed ? UPDATE_NEEDS_CHECK_NOTE : undefined}
                  onClick={() => onUpdate(places, null, scopes)}
                >
                  {UPDATE_PACKAGE_EVERYWHERE_LABEL}
                </Button>
              ) : null}
            </TableCell>
          </>
        )}
      </TableRow>
      {/* A place row names a place, so the whole of it opens that place —
          the same narrowing its Where cell opens, on the pointer and on
          Enter. The package is the row above's to open. */}
      {open && !only
        ? places.map((row, index) => (
            <TableRow
              key={placeKey(row)}
              id={index === 0 ? placesId : undefined}
              {...opensOnActivate(
                () => goToLibrary({ scope: selectionOf(row.scope) }),
                opensLabel(placeName(row.scope, scopes)),
              )}
              className="cursor-pointer bg-muted/20"
            >
              <TableCell colSpan={2} />
              <PlaceCells
                row={row}
                among={scopes}
                onIgnore={onIgnore}
                onUpdate={
                  onUpdate ? (one) => onUpdate([one], null, scopes) : undefined
                }
              />
            </TableRow>
          ))
        : null}
    </>
  );
}
