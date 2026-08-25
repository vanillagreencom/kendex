import { ChevronDown, ChevronRight } from "lucide-react";
import { useId, useState } from "react";
import type { UpdateRow } from "@/bindings";
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
import {
  EDITED_UPDATE_TAG,
  PINNED_UPDATE_TAG,
  REMOVED_UPSTREAM_TAG,
} from "@/lib/copy";
import {
  EDITED_TAG_HELP,
  heldInLabel,
  placesLabel,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATE_PACKAGE_EVERYWHERE_LABEL,
} from "@/lib/copy-updates";
import { kindIcon } from "@/lib/kind-icon";
import { kindLabel, packageDisplayName } from "@/lib/labels";
import {
  groupKey,
  groupUpdates,
  placeKey,
  type UpdateGroup,
  updatablePlaces,
} from "@/lib/update-groups";
import { rowUnsettled } from "@/lib/updates-read-state";
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
}: {
  rows: UpdateRow[];
  /** Absent for muted rows: their only extra action is "notify again". */
  onIgnore?: (row: UpdateRow) => void;
  /** Present on the table that carries the `…` menu showing the Version
   *  column; the column itself follows the page-wide choice. */
  onShowVersion?: (show: boolean) => void;
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
  defaultOpen = false,
}: {
  group: UpdateGroup;
  onIgnore?: (row: UpdateRow) => void;
  defaultOpen?: boolean;
}) {
  const [open, setOpen] = useState(defaultOpen);
  const placesId = useId();
  const busy = useUpdatesStore((s) => s.busy);
  const places = group.places;
  // Not loaded, mid-check, mid-load, and a follow switch settling in any of
  // these places' scopes hold Update alike: either way these are not the
  // rows an update would act on.
  const unconfirmed = useUpdatesStore((s) =>
    places.some((place) => rowUnsettled(s, place)),
  );
  const showVersion = useUpdatesView((s) => s.showVersion);
  const updateRows = useUpdatesStore((s) => s.updateRows);
  const Icon = kindIcon(group.kind);
  const name = packageDisplayName(group);
  const scopes = places.map((place) => place.scope);
  const only = places.length === 1 ? places[0] : null;
  const Chevron = open ? ChevronDown : ChevronRight;
  const held = places.filter((p) => p.pinned).length;
  const tags = [
    held === places.length
      ? PINNED_UPDATE_TAG
      : held > 0
        ? heldInLabel(held, places.length)
        : null,
    places.some((p) => p.blockedByLocalEdit) ? EDITED_UPDATE_TAG : null,
    places.some((p) => p.removedUpstream) ? REMOVED_UPSTREAM_TAG : null,
  ].filter((tag) => tag !== null);

  return (
    <>
      <TableRow>
        <TableCell>
          <div className="flex min-w-0 items-center gap-2.5">
            <Icon className="size-4 shrink-0 text-muted-foreground" />
            <span className="truncate font-medium">{name}</span>
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
          <PlaceCells row={only} among={scopes} onIgnore={onIgnore} />
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
            <TableCell />
            <TableCell className="text-right">
              {/* Muted places only offer "notify again", so there is
                  nothing for a package-wide Update to do. */}
              {onIgnore ? (
                <Button
                  size="sm"
                  variant="outline"
                  disabled={
                    busy || unconfirmed || updatablePlaces(places).length === 0
                  }
                  title={unconfirmed ? UPDATE_NEEDS_CHECK_NOTE : undefined}
                  onClick={() => void updateRows(places)}
                >
                  {UPDATE_PACKAGE_EVERYWHERE_LABEL}
                </Button>
              ) : null}
            </TableCell>
          </>
        )}
      </TableRow>
      {open && !only
        ? places.map((row, index) => (
            <TableRow
              key={placeKey(row)}
              id={index === 0 ? placesId : undefined}
              className="bg-muted/20"
            >
              <TableCell colSpan={2} />
              <PlaceCells row={row} among={scopes} onIgnore={onIgnore} />
            </TableRow>
          ))
        : null}
    </>
  );
}
