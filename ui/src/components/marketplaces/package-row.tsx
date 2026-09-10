import { type ComponentProps, useEffect } from "react";
import type { AvailablePackage, Catalog, Scope } from "@/bindings";
import { Ago } from "@/components/ago";
import { InstalledIn } from "@/components/marketplaces/installed-in";
import { PackageName } from "@/components/package/package-name";
import { ScoreTooltip } from "@/components/score-tooltip";
import { StatusDot } from "@/components/status-dot";
import { TagBadges } from "@/components/tag-badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { TableCell, TableRow } from "@/components/ui/table";
import { INSTALL_ACTION } from "@/lib/copy-install";
import {
  LOCAL_FOLDER_LABEL,
  PACKAGE_STATE_UNKNOWN,
  SUBSCRIBE_TO_INSTALL_LABEL,
} from "@/lib/copy-marketplaces";
import {
  SAFETY_DOT_UNCHECKED,
  safetyDotWords,
  severityTone,
} from "@/lib/copy-safety";
import { offersInstall } from "@/lib/install-state";
import { kindIcon } from "@/lib/kind-icon";
import { kindLabel, packageDisplayName, shortRevision } from "@/lib/labels";
import { type MarketplaceDisplay, sourceLine } from "@/lib/marketplace-display";
import { opensLabel, opensOnActivate } from "@/lib/opens-on-activate";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";
import { safetyKey, usePreinstallSafety } from "@/stores/preinstall-safety";

/** One offered package with the catalog it comes from, and whether the
 * scope that catalog is subscribed in has a readable lock right now.
 *
 * `row.state` is cached per package and refreshed only when the catalog is
 * read again; `recordsUnreadable` comes from the overview row that produced
 * this entry, which every load refreshes. So the two can disagree — a scope
 * readable when its packages were cached, damaged while the app stayed
 * open — and the fresh one wins. Required rather than optional so a caller
 * cannot build an entry that leaves the scope's answer out. */
export interface PackageEntry {
  catalog: Catalog;
  row: AvailablePackage;
  recordsUnreadable: boolean;
  /** What the subscription declares it reads — a pinned commit, or the tag
   * or branch it tracks — else the commit it currently reads, which the
   * cache holds and which moves as a tracked ref moves. Shown as-is unless
   * it is a commit id, which is shortened. */
  revision?: string | null;
}

/** Which of the columns beyond the four every width keeps are on screen.
 * The table settles this once from its own room and hands it down, so the
 * header and every row draw the same set. */
export interface PackageColumns {
  tags: boolean;
  marketplace: boolean;
  updated: boolean;
  places: boolean;
}

/** One row of [PackagesTable]: the package, what it is, when it last
 * changed, how it scored, where it is installed from this marketplace, and
 * the one thing this table can do with it. Whether a bare repository's row
 * may subscribe is not its decision — the table settles that once, from the
 * same reading the page header uses. */
export function PackageRow({
  entry,
  columns,
  marketplace,
  places,
  offerSubscribe,
  selectable,
  selected,
  onToggle,
  onInstall,
}: {
  entry: PackageEntry;
  /** Which of the optional columns this row draws. The table settles it
   *  from its own room, so the header and the body never disagree. A
   *  marketplace's own page says where each of its packages landed; the
   *  cross-marketplace list names the marketplace in that room instead. */
  columns: PackageColumns;
  /** What this row's marketplace is called and where it comes from —
   *  `lib/marketplace-display.ts`, resolved once by the table against the
   *  live subscription rows, so a local checkout declared under the alias
   *  `.` reads here as the name its catalogue declares. Absent where the
   *  column is not drawn. */
  marketplace: MarketplaceDisplay | undefined;
  /** Where this package is installed from this marketplace. The table
   *  builds the whole index once — see `lib/installed-places.ts` — so a row
   *  neither scans the provenance join nor subscribes to it. */
  places: Scope[];
  /** Whether a bare repository's row may subscribe and install — decided
   * once for the table, never per row. */
  offerSubscribe: boolean;
  /** Whether this row can join a selection. A row with nothing to install
   *  carries the cell without a box, so every row keeps the same columns
   *  and the table does not shift as states change. */
  selectable: boolean;
  selected: boolean;
  onToggle: () => void;
  /** Install this row alone. The one-package case of the same guided flow
   *  a selection opens, never a second install path. `as` is the catalog
   *  to ask against where it is not the one the row was drawn from: a bare
   *  repository's row subscribes first, and the subscription it gains is
   *  what the flow installs from. */
  onInstall: (as?: Catalog) => void;
}) {
  const { catalog, row, recordsUnreadable } = entry;
  const goToAvailablePackage = useNavStore((s) => s.goToAvailablePackage);
  const goToMarketplace = useNavStore((s) => s.goToMarketplace);
  const subscribeForInstall = useMarketplacesStore(
    (s) => s.subscribeForInstall,
  );
  const busy = useMarketplacesStore((s) => s.busy);
  const want = usePreinstallSafety((s) => s.want);
  const safety = usePreinstallSafety(
    (s) => s.scores[safetyKey(catalog, row.kind, row.name)],
  );
  const Icon = kindIcon(row.kind);

  useEffect(() => {
    want(catalog, row.kind, row.name);
  }, [want, catalog, row.kind, row.name]);

  const openPackage = () =>
    goToAvailablePackage({ catalog, kind: row.kind, name: row.name });
  // The whole row opens the package, for the pointer and the keyboard
  // alike; Install stays a control of its own inside it.
  const open = opensOnActivate(
    openPackage,
    opensLabel(packageDisplayName(row)),
  );

  const updated = row.updatedAt ? Date.parse(row.updatedAt) : Number.NaN;
  return (
    <TableRow className="cursor-pointer" {...open}>
      {/* Ticking a row is not opening it. The box draws as a button, and
          `opensOnActivate` reads a control inside the surface as having
          answered the click, so the row stays put under a tick. */}
      <TableCell className="w-8">
        {selectable ? (
          <Checkbox
            checked={selected}
            aria-label={`Select ${packageDisplayName(row)}`}
            onCheckedChange={onToggle}
          />
        ) : null}
      </TableCell>
      {/* The one column with no width of its own, so without a ceiling a
          long summary sets the whole table's, pushes every other column
          past the right edge, and leaves the reader a name and nothing
          else. `packages-table.tsx` sets the number and says what by. */}
      <TableCell className="max-w-72">
        <div className="flex min-w-0 items-center gap-2.5">
          <Icon className="size-4 shrink-0 text-muted-foreground" />
          <div className="min-w-0">
            {/* What a screen reader is told opens the package. The row
                opens too, but a row announces its cells rather than an
                action, so the name stays a real control. Hovering or
                focusing it previews the author's words, the same way the
                Library row does. */}
            <PackageName
              name={packageDisplayName(row)}
              summary={row.summary}
              onOpen={openPackage}
              className="max-w-full font-medium"
            />
            {row.summary ? (
              <div className="truncate text-xs text-muted-foreground">
                {row.summary}
              </div>
            ) : null}
          </div>
        </div>
      </TableCell>
      <TableCell className="text-muted-foreground">
        {kindLabel(row.kind)}
      </TableCell>
      {columns.tags ? (
        <TableCell className="max-w-48">
          <TagBadges tags={row.tags} />
        </TableCell>
      ) : null}
      {columns.marketplace ? (
        // A catalog declares one name however many places hold it, so a
        // working checkout and the remote catalogue it came from read alike
        // here. The folder says so under its name, in the room a remote's
        // revision uses — a folder source has no revision, so the two never
        // compete — and the full location is on the cell for a pointer.
        <TableCell
          className="max-w-40 text-muted-foreground"
          title={marketplace ? sourceLine(marketplace) : undefined}
        >
          {/* The name it resolved to opens the marketplace it names, the
              same as its own card on the Subscribed tab. */}
          <button
            type="button"
            className="block max-w-full truncate hover:underline"
            onClick={() => goToMarketplace(catalog)}
          >
            {marketplace?.name}
          </button>
          {marketplace?.local ? (
            <div className="truncate text-xs">{LOCAL_FOLDER_LABEL}</div>
          ) : null}
          {entry.revision ? (
            <div className="truncate font-mono text-xs">
              @ {shortRevision(entry.revision)}
            </div>
          ) : null}
        </TableCell>
      ) : null}
      {columns.updated ? (
        <TableCell className="text-muted-foreground">
          {Number.isNaN(updated) ? (
            // A catalog kendex keeps no history for has no date to show,
            // and a guess would be this machine's clock rather than the
            // package's.
            <span aria-hidden>—</span>
          ) : (
            <Ago at={updated} exact={row.updatedAt} />
          )}
        </TableCell>
      ) : null}
      <TableCell>
        {safety ? (
          <SafetyDot
            tone={severityTone(safety.findings)}
            words={safetyDotWords(
              safety.safety.score,
              safety.skipped.length,
              safety.findings,
            )}
          />
        ) : (
          <SafetyDot tone="muted" words={SAFETY_DOT_UNCHECKED} />
        )}
      </TableCell>
      {columns.places ? (
        <TableCell className="max-w-40 truncate text-muted-foreground">
          {places.length > 0 ? (
            <InstalledIn places={places} />
          ) : (
            <span aria-hidden>—</span>
          )}
        </TableCell>
      ) : null}
      <TableCell className="text-right">
        {row.state === "installed" ? (
          <span className="text-xs text-muted-foreground">Installed</span>
        ) : row.state === "not-offered" ? (
          <span className="text-xs text-muted-foreground">
            No longer offered
          </span>
        ) : recordsUnreadable || row.state === "unknown" ? (
          // This place's lock could not be read, so nothing here knows
          // whether the package is installed — and an install would meet
          // the same unreadable record, so no button offers one. The
          // scope's own answer is read first: a cached row from before the
          // record broke still says "available", and it must not outvote
          // the fresher fact beside it.
          <span className="text-xs text-muted-foreground">
            {PACKAGE_STATE_UNKNOWN}
          </span>
        ) : catalog.by === "repo" ? (
          // Installing needs a subscription, so this click makes one —
          // personally — and then asks the same two questions every other
          // install asks, against the subscription it just gained. The
          // line above the table says the subscribing part once. Where a
          // subscription already declares the repository the offer is not
          // this table's to make: the header carries the one action, and
          // the row goes back to saying the package is here.
          offerSubscribe ? (
            <Button
              size="sm"
              variant="outline"
              disabled={busy}
              onClick={() => {
                void subscribeForInstall(catalog.repo).then((made) => {
                  if (made) onInstall(made);
                });
              }}
            >
              {SUBSCRIBE_TO_INSTALL_LABEL}
            </Button>
          ) : (
            <span className="text-xs text-muted-foreground">Available</span>
          )
        ) : offersInstall(row.state) ? (
          // Scores arrive one at a time, and a read that fails leaves a
          // row without one until it mounts again, so a row is offered
          // before its dot resolves. The score is advisory and never holds
          // an install back, so the dot's words say a result is missing
          // instead of the row going quiet.
          <Button
            size="sm"
            variant="outline"
            disabled={busy}
            onClick={() => onInstall()}
          >
            {INSTALL_ACTION}
          </Button>
        ) : null}
      </TableCell>
    </TableRow>
  );
}

/** A row's safety reading: the colour, and the words the colour stands for.
 *  A row installs from the list without the package's page ever opening, so
 *  the words have to be reachable from the row itself — the trigger takes
 *  focus, putting them a tab before Install, and they sit in the row's text
 *  for anyone who never hovers. */
function SafetyDot({
  tone,
  words,
}: {
  tone: ComponentProps<typeof StatusDot>["tone"];
  words: string;
}) {
  return (
    <ScoreTooltip words={words} side="left">
      <StatusDot tone={tone} />
    </ScoreTooltip>
  );
}
