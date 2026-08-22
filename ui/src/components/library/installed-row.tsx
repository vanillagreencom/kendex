import { memo } from "react";
import type { HarnessId, Origin } from "@/bindings";
import { HarnessBadge } from "@/components/harness-badge";
import { StatusDot } from "@/components/status-dot";
import { TagBadges } from "@/components/tag-badge";
import { Badge } from "@/components/ui/badge";
import { TableCell, TableRow } from "@/components/ui/table";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import {
  bundledWithLabel,
  ORIGIN_UNCONFIRMED,
  originUnconfirmedTitle,
  vendorHelp,
} from "@/lib/copy";
import {
  customizedPlacesLabel,
  forkedInLabel,
  forkedPlacesLabel,
  placeStateLine,
  STATUS_LABELS,
} from "@/lib/copy-customize";
import {
  customizedPlaces,
  forkedPlaces,
  type PlaceStanding,
  uncheckedPlaces,
} from "@/lib/customized-places";
import {
  type GroupStatus,
  groupStatus,
  groupVendor,
  type ItemGroup,
} from "@/lib/derive";
import { kindIcon } from "@/lib/kind-icon";
import {
  describesItself,
  hookDisplayName,
  kindLabel,
  scopeName,
  scopePath,
} from "@/lib/labels";
import { relativeTime } from "@/lib/relative-time";
import { cn } from "@/lib/utils";
import { originLabel, originTitle } from "@/stores/provenance";

/** The mark sits inside a row that opens the package where it was
 *  installed from; its own click means the place it names instead, so it
 *  must never also fire the row's. */
export const markClick =
  (open: () => void) =>
  (event: { stopPropagation: () => void }): void => {
    event.stopPropagation();
    open();
  };

const STATUS_TONES: Record<GroupStatus, "good" | "warning" | "critical"> = {
  active: "good",
  off: "warning",
  broken: "critical",
};

function Row({
  group,
  origin,
  originError,
  standings,
  onOpen,
  onOpenPlace,
}: {
  group: ItemGroup;
  origin: Origin | null;
  /** Why the join could not be re-read, or null. The origin shown is then
   *  the last one that loaded, and saying so is the difference between an
   *  answer kept and an answer confirmed. */
  originError: string | null;
  /** What is known about each place this package is installed in. */
  standings: PlaceStanding[];
  /** Opens the package where it was installed from. Handed the row's own
   *  group rather than closing over it, so the table can keep one function
   *  for every row and the row can stay memoized. */
  onOpen: (group: ItemGroup) => void;
  /** Opens the place the mark names, on what was changed there. */
  onOpenPlace: (group: ItemGroup, standings: PlaceStanding[]) => void;
}) {
  const Icon = kindIcon(group.kind);
  const displayName =
    group.kind === "hook" ? hookDisplayName(group.name) : group.name;
  const vendor = groupVendor(group);
  // The standings were built from this group's places, in that order, so
  // asking the group a second time would be asking the same question twice.
  const scopes = standings.map((one) => one.scope);
  const status = groupStatus(group);
  const whereLabel =
    scopes.length === 1 ? scopeName(scopes[0]) : `${scopes.length} locations`;
  // The full path, so two projects sharing a folder name stay apart, and
  // what is known about each — including that nothing is.
  const whereTitle = standings
    .map((one) =>
      placeStateLine(scopePath(one.scope) ?? scopeName(one.scope), one.state),
    )
    .join("\n");
  const changed = customizedPlaces(standings);
  const forks = forkedPlaces(standings);
  // The one thing the row says about your changes: which place, or how many
  // of them. Every other surface says it the same way.
  const mark =
    changed.length > 0
      ? customizedPlacesLabel(
          changed.map((where) => scopeName(where, scopes)),
          scopes.length,
          uncheckedPlaces(standings),
        )
      : null;

  return (
    <TableRow onClick={() => onOpen(group)} className="cursor-pointer">
      {/* Cells are nowrap by default; the description is the one column that
          wants to wrap rather than run out of the row and get cut mid-word. */}
      <TableCell className="max-w-[22rem] font-medium whitespace-normal">
        <span className="flex items-start gap-2">
          {/* The kind icon carries the customization colour, the legend
              above the table names what it means, and the Where cell in
              this same row repeats it in words. */}
          <span title={mark ?? undefined} className="mt-0.5 shrink-0">
            <Icon
              className={cn(
                "size-4",
                mark ? "text-customized" : "text-muted-foreground",
              )}
            />
          </span>
          <span className="min-w-0">
            <span className="flex items-center gap-1.5">
              <span className="block truncate">{displayName}</span>
              {forks.length > 0 ? (
                // The place is in the badge, not only in its tooltip: a
                // mark that says which place it is about says nothing to
                // anyone reading by touch or by keyboard otherwise. The
                // tooltip still carries the full list.
                <Badge
                  variant="outline"
                  title={forkedInLabel(
                    forks.map((where) => scopeName(where, scopes)),
                  )}
                >
                  {forkedPlacesLabel(
                    forks.map((where) => scopeName(where, scopes)),
                    scopes.length,
                    uncheckedPlaces(standings),
                  )}
                </Badge>
              ) : null}
              {vendor ? (
                <Badge variant="outline" title={vendorHelp(vendor)}>
                  {bundledWithLabel(group.installations[0].harness)}
                </Badge>
              ) : null}
            </span>
            {group.description ? (
              <span
                className={cn(
                  "line-clamp-2 text-xs font-normal text-muted-foreground",
                  !describesItself(group.kind) && "font-mono text-[11px]",
                )}
              >
                {group.description}
              </span>
            ) : null}
          </span>
        </span>
      </TableCell>
      <TableCell className="align-top text-muted-foreground">
        {kindLabel(group.kind)}
      </TableCell>
      <TableCell className="align-top">
        <TagBadges tags={group.tags} />
      </TableCell>
      <TableCell>
        <span className="flex flex-wrap gap-1">
          {group.harnesses.map((h) => (
            <HarnessBadge key={h} harness={h as HarnessId} compact />
          ))}
          {group.shared ? (
            <Badge variant="secondary">Shared files</Badge>
          ) : null}
        </span>
      </TableCell>
      {/* Where a package is changed is where you go to see the change, so
          the mark is the way there — the row itself still opens the place
          it was installed from. */}
      <TableCell title={whereTitle} className="text-muted-foreground">
        {mark ? (
          <button
            type="button"
            className="max-w-[13rem] text-left whitespace-normal text-customized hover:underline"
            onClick={markClick(() => onOpenPlace(group, standings))}
          >
            {mark}
          </button>
        ) : (
          whereLabel
        )}
        <span className="sr-only">{whereTitle}</span>
      </TableCell>
      <TableCell
        title={
          originError
            ? originUnconfirmedTitle(originError)
            : originTitle(origin)
        }
        className="text-muted-foreground"
      >
        {originLabel(origin) || "—"}
        {originError && origin ? (
          <span className="ml-1.5 text-xs">{ORIGIN_UNCONFIRMED}</span>
        ) : null}
      </TableCell>
      <TableCell className="text-right text-xs text-muted-foreground">
        {group.modifiedAt != null
          ? relativeTime(group.modifiedAt * 1000, Date.now())
          : "—"}
      </TableCell>
      {/* A dot, not a word: seven rows of "Active" say nothing the colour
          doesn't, and the words are back on hover for anyone who wants them. */}
      <TableCell>
        <Tooltip>
          <TooltipTrigger
            render={
              <span className="flex w-full justify-center py-1">
                <StatusDot tone={STATUS_TONES[status]} />
                <span className="sr-only">{STATUS_LABELS[status]}</span>
              </span>
            }
          />
          <TooltipContent side="left">{STATUS_LABELS[status]}</TooltipContent>
        </Tooltip>
      </TableCell>
    </TableRow>
  );
}

/** Rows are pure in their props, and the table re-joins its standings on
 *  every updates reload — most of which move nothing. */
export const InstalledRow = memo(Row);
