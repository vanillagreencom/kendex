import type { HarnessId, Origin, Scope } from "@/bindings";
import { Ago } from "@/components/ago";
import { HarnessBadge } from "@/components/harness-badge";
import { PackageName } from "@/components/package/package-name";
import { SharedFilesBadge } from "@/components/shared-files-badge";
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
  FORKED_BADGE_HELP,
  FORKED_BADGE_LABEL,
  MISSING_FILES_BADGE_HELP,
  MISSING_FILES_BADGE_LABEL,
  vendorHelp,
} from "@/lib/copy";
import { STATUS_LABELS } from "@/lib/copy-customize";
import { UPDATE_AVAILABLE_BADGE } from "@/lib/copy-updates";
import {
  type GroupStatus,
  groupScopes,
  groupStatus,
  groupVendor,
  type ItemGroup,
  sharedFiles,
} from "@/lib/derive";
import { kindIcon } from "@/lib/kind-icon";
import { hookDisplayName, kindLabel, scopeName } from "@/lib/labels";
import { opensLabel, opensOnActivate } from "@/lib/opens-on-activate";
import { scopeKey } from "@/lib/scope";
import { placeName } from "@/lib/update-groups";
import { originLabel, originTitle } from "@/stores/provenance";

const STATUS_TONES: Record<GroupStatus, "good" | "warning" | "critical"> = {
  active: "good",
  off: "warning",
  broken: "critical",
};

export function InstalledRow({
  group,
  origin,
  forkedIn,
  outOfDate,
  missingIn,
  onOpen,
  onOpenHarness,
  onOpenPlace,
  onOpenFrom,
}: {
  group: ItemGroup;
  origin: Origin | null;
  /** The places whose copy is the reader's own fork. A fork belongs to the
   *  place it was made in, like every other per-place fact. */
  forkedIn: Scope[];
  /** The source has moved on from what is installed, in at least one of
   *  this package's places. A mark and not a control: the update itself is
   *  the same one flow wherever it is taken, and this row's own click
   *  already opens the package. */
  outOfDate: boolean;
  /** The places where a file kendex installed for this package is gone.
   *  The repair lives on the package page, so the badge opens it there. */
  missingIn: Scope[];
  onOpen: (scope?: Scope) => void;
  /** Open one of the tools this package is installed for. */
  onOpenHarness: (harness: HarnessId) => void;
  /** Open the one place this package is installed in. A package in
   *  several has no single place to open, so the cell counts them
   *  instead and the reader picks one on the package's own page. */
  onOpenPlace: (scope: Scope) => void;
  /** Open the marketplace this copy came from, where it came from one —
   *  absent for a package the reader wrote or one nothing manages. */
  onOpenFrom?: () => void;
}) {
  const Icon = kindIcon(group.kind);
  const displayName =
    group.kind === "hook" ? hookDisplayName(group.name) : group.name;
  const vendor = groupVendor(group);
  const shared = sharedFiles(group.installations);
  const scopes = groupScopes(group);
  // The places a badge is named against: the scan's, and the ones whose
  // copy is gone — a place the scan cannot see is still one of this
  // row's, and two same-named folders among them have to read apart.
  const named = [...scopes, ...missingIn];
  const status = groupStatus(group);
  const whereLabel =
    scopes.length === 1 ? scopeName(scopes[0]) : `${scopes.length} locations`;
  const whereTitle = scopes
    .map((s) => (s.scope === "global" ? "Personal" : s.root))
    .join(", ");

  return (
    <TableRow
      // A shortcut for the pointer and the keyboard alike, on top of the
      // name's own button: the row reads as one target, so clicking any of
      // its cells — or pressing Enter on the row — opens the package.
      {...opensOnActivate(() => onOpen(), opensLabel(displayName))}
      className="cursor-pointer"
    >
      {/* Cells are nowrap by default; the description is the one column that
          wants to wrap rather than run out of the row and get cut mid-word. */}
      <TableCell className="max-w-[22rem] font-medium whitespace-normal">
        <span className="flex items-start gap-2">
          {/* The list says nothing about customization: whether a package
              is changed, and where, is the package page's to say. */}
          <span className="mt-0.5 shrink-0">
            <Icon className="size-4 text-muted-foreground" />
          </span>
          <span className="min-w-0">
            <span className="flex items-center gap-1.5">
              {/* What a screen reader is told opens the package. The row
                  itself opens too, but a row announces its cells rather
                  than an action, so the name stays a real button. No
                  selection guard here: a completed click on a button is
                  always intent, and the row's own guard declines the
                  drags. Hovering or focusing it previews what the package
                  is for, where its author said. */}
              <PackageName
                name={displayName}
                summary={group.summary}
                onOpen={() => onOpen()}
              />
              {/* One badge per place. A single "Forked" over several tells
                  the reader it happened and not where, and leaves nothing
                  to open — a fork belongs to the place it was made in. */}
              {forkedIn.map((where) => (
                // "Forked" is the app's word, not the reader's: what it
                // costs them is the paused updates, and that arrives on
                // hover, on focus and through the button's own name.
                <Tooltip key={scopeKey(where)}>
                  <TooltipTrigger
                    render={
                      <Badge
                        variant="outline"
                        className="cursor-pointer"
                        render={
                          <button type="button" onClick={() => onOpen(where)}>
                            {`${FORKED_BADGE_LABEL} in ${placeName(where, scopes)}`}
                            <span className="sr-only">{FORKED_BADGE_HELP}</span>
                          </button>
                        }
                      />
                    }
                  />
                  <TooltipContent className="max-w-80">
                    {FORKED_BADGE_HELP}
                  </TooltipContent>
                </Tooltip>
              ))}
              {missingIn.map((where) => (
                <Tooltip key={scopeKey(where)}>
                  <TooltipTrigger
                    render={
                      <Badge
                        variant="warning"
                        className="cursor-pointer"
                        render={
                          <button type="button" onClick={() => onOpen(where)}>
                            {`${MISSING_FILES_BADGE_LABEL} in ${placeName(where, named)}`}
                            <span className="sr-only">
                              {MISSING_FILES_BADGE_HELP}
                            </span>
                          </button>
                        }
                      />
                    }
                  />
                  <TooltipContent className="max-w-80">
                    {MISSING_FILES_BADGE_HELP}
                  </TooltipContent>
                </Tooltip>
              ))}
              {outOfDate ? (
                <Badge variant="secondary">{UPDATE_AVAILABLE_BADGE}</Badge>
              ) : null}
              {vendor ? (
                // A title alone answers a pointer and nothing else; the
                // same words reach the keyboard and a screen reader here.
                <Tooltip>
                  <TooltipTrigger
                    render={
                      <Badge variant="outline" tabIndex={0}>
                        {bundledWithLabel(group.installations[0].harness)}
                        <span className="sr-only">{vendorHelp(vendor)}</span>
                      </Badge>
                    }
                  />
                  <TooltipContent className="max-w-80">
                    {vendorHelp(vendor)}
                  </TooltipContent>
                </Tooltip>
              ) : null}
            </span>
            {/* The author's own words, in the same voice as every other
                description on screen. A package whose author wrote none
                gets no line: a command, a URL or a path is what the
                package runs, not what it is for, and the technical view
                is where those belong. */}
            {group.summary ? (
              <span className="line-clamp-2 text-xs font-normal text-muted-foreground">
                {group.summary}
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
          {/* A chip names a harness, so it opens that harness's own view
              of what is installed for it. */}
          {group.harnesses.map((h) => (
            <HarnessBadge
              key={h}
              harness={h as HarnessId}
              compact
              onOpen={() => onOpenHarness(h as HarnessId)}
            />
          ))}
          <SharedFilesBadge files={shared} />
        </span>
      </TableCell>
      {/* A place names a thing, so it opens it — but only where the cell
          names one place. "3 locations" is a count, and the places behind
          it are listed on the package's own page. */}
      <TableCell title={whereTitle} className="text-muted-foreground">
        {scopes.length === 1 ? (
          <button
            type="button"
            className="hover:underline"
            onClick={() => onOpenPlace(scopes[0])}
          >
            {whereLabel}
          </button>
        ) : (
          whereLabel
        )}
      </TableCell>
      {/* Same rule for where the copy came from: a marketplace's name
          opens the marketplace. "Your own" and "Not managed" name no
          marketplace, so they stay text. */}
      <TableCell title={originTitle(origin)} className="text-muted-foreground">
        {onOpenFrom && originLabel(origin) ? (
          <button
            type="button"
            className="hover:underline"
            onClick={onOpenFrom}
          >
            {originLabel(origin)}
          </button>
        ) : (
          originLabel(origin) || "—"
        )}
      </TableCell>
      <TableCell className="text-right text-xs text-muted-foreground">
        {group.modifiedAt != null ? <Ago at={group.modifiedAt * 1000} /> : "—"}
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
