import type { HarnessId, Origin, Scope } from "@/bindings";
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
import { bundledWithLabel, FORKED_BADGE_LABEL, vendorHelp } from "@/lib/copy";
import { STATUS_LABELS } from "@/lib/copy-customize";
import {
  type GroupStatus,
  groupScopes,
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
} from "@/lib/labels";
import type { PlaceMark } from "@/lib/place-marks";
import { relativeTime } from "@/lib/relative-time";
import { scopeKey } from "@/lib/scope";
import { placeName } from "@/lib/update-groups";
import { cn } from "@/lib/utils";
import { originLabel, originTitle } from "@/stores/provenance";

const STATUS_TONES: Record<GroupStatus, "good" | "warning" | "critical"> = {
  active: "good",
  off: "warning",
  broken: "critical",
};

export function InstalledRow({
  group,
  origin,
  mark,
  forkedIn,
  onOpen,
}: {
  group: ItemGroup;
  origin: Origin | null;
  /** What this package holds where, and the place a click on it opens.
   *  Null where no place holds anything of the reader's. */
  mark: PlaceMark | null;
  /** The places whose copy is the reader's own fork. A fork belongs to the
   *  place it was made in, like every other per-place fact. */
  forkedIn: Scope[];
  onOpen: (scope?: Scope) => void;
}) {
  const Icon = kindIcon(group.kind);
  const customized = mark !== null;
  const displayName =
    group.kind === "hook" ? hookDisplayName(group.name) : group.name;
  const vendor = groupVendor(group);
  const scopes = groupScopes(group);
  const status = groupStatus(group);
  const whereLabel =
    scopes.length === 1 ? scopeName(scopes[0]) : `${scopes.length} locations`;
  const whereTitle = scopes
    .map((s) => (s.scope === "global" ? "Personal" : s.root))
    .join(", ");

  return (
    <TableRow onClick={() => onOpen()} className="cursor-pointer">
      {/* Cells are nowrap by default; the description is the one column that
          wants to wrap rather than run out of the row and get cut mid-word. */}
      <TableCell className="max-w-[22rem] font-medium whitespace-normal">
        <span className="flex items-start gap-2">
          {/* The one place colour says something other than "which tool":
              the Library's legend names it, and the row still says so in
              words for anyone who cannot see the difference. */}
          <span className="mt-0.5 shrink-0">
            <Icon
              className={cn(
                "size-4",
                customized ? "text-customized" : "text-muted-foreground",
              )}
            />
          </span>
          <span className="min-w-0">
            <span className="flex items-center gap-1.5">
              <span className="block truncate">{displayName}</span>
              {/* One badge per place. Collapsing several to a bare "Forked"
                  is the same fault as the customized mark had: the reader
                  is told it happened and not where, and the badge that
                  named no place could not be followed either. */}
              {forkedIn.map((where) => (
                <Badge
                  key={scopeKey(where)}
                  variant="outline"
                  className="cursor-pointer"
                  render={
                    <button
                      type="button"
                      onClick={(event) => {
                        event.stopPropagation();
                        onOpen(where);
                      }}
                    >
                      {`${FORKED_BADGE_LABEL} in ${placeName(where, scopes)}`}
                    </button>
                  }
                />
              ))}
              {vendor ? (
                <Badge variant="outline" title={vendorHelp(vendor)}>
                  {bundledWithLabel(group.installations[0].harness)}
                </Badge>
              ) : null}
            </span>
            {/* In words on the row, not only in a tooltip: the whole point
                of the mark is saying which place is the reader's, and a
                fact only a hover reveals is a fact most readers never get.
                It opens the place it names. */}
            {mark?.goTo ? (
              <button
                type="button"
                onClick={(event) => {
                  event.stopPropagation();
                  onOpen(mark.goTo ?? undefined);
                }}
                className="mt-0.5 block text-left text-xs text-customized hover:underline"
              >
                {mark.label}
              </button>
            ) : mark ? (
              // Several places, so the mark names no one destination.
              // Sending it to the row's primary place would open somewhere
              // the label never mentioned, and possibly one holding nothing
              // of the reader's.
              <span className="mt-0.5 block text-xs text-customized">
                {mark.label}
              </span>
            ) : null}
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
      <TableCell title={whereTitle} className="text-muted-foreground">
        {whereLabel}
      </TableCell>
      <TableCell title={originTitle(origin)} className="text-muted-foreground">
        {originLabel(origin) || "—"}
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
