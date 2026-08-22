import { useCallback, useMemo } from "react";
import type { Origin } from "@/bindings";
import { InstalledRow } from "@/components/library/installed-row";
import { InstalledSkeleton } from "@/components/library/installed-skeleton";
import { LibraryLegend } from "@/components/library/library-legend";
import { TableEmptyRow } from "@/components/library/table-empty";
import { MarksNote } from "@/components/marks-note";
import {
  Table,
  TableBody,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { TAGS_ROW_LABEL } from "@/lib/copy";
import {
  anyCustomized,
  type PlaceStanding,
  placeStandings,
} from "@/lib/customized-places";
import { groupScopes, type ItemGroup } from "@/lib/derive";
import { markNav } from "@/lib/place-marks";
import { usePlacesSource } from "@/lib/places-source";
import { useNavStore } from "@/stores/nav";
import { originFor, useProvenanceStore } from "@/stores/provenance";

/** The Library's table: one row per package, each carrying what is known
 *  about every place it is installed in. */
export function InstalledTable({
  groups,
  origins,
  scanning,
  hasAnyItems,
  onClearFilters,
  onBrowse,
}: {
  groups: ItemGroup[];
  /** Provenance keyed by place, so the join asks rather than scans. */
  origins: Map<string, Origin>;
  /** Nothing has been counted yet — distinct from "counted, found none". */
  scanning: boolean;
  hasAnyItems: boolean;
  onClearFilters: () => void;
  onBrowse: () => void;
}) {
  const goToPackage = useNavStore((s) => s.goToPackage);
  const places = usePlacesSource();
  // One join per change of its inputs, and every handler kept stable, so a
  // reload that moved nothing re-renders no row. That rests on both stores
  // handing back their previous value when a re-read says the same thing
  // (lib/same-read.ts): a fresh array of identical rows would defeat every
  // memo below it.
  // The join keeps its rows when a re-read fails, so the origins below are
  // still worth drawing — and are the last ones kendex could read rather
  // than the ones it just confirmed. The package page says so; so does this.
  const originError = useProvenanceStore((s) => s.error);
  const rows = useMemo(
    () =>
      groups.map((group) => {
        const scopes = groupScopes(group);
        return {
          group,
          standings: placeStandings(places, group.kind, group.name, scopes),
          origin: originFor(origins, group.kind, group.name, scopes),
        };
      }),
    [groups, places, origins],
  );
  const openRow = useCallback(
    (group: ItemGroup) => {
      const primary = group.installations[0];
      if (!primary) return;
      goToPackage({ kind: group.kind, name: group.name, scope: primary.scope });
    },
    [goToPackage],
  );
  const openMark = useCallback(
    (group: ItemGroup, standings: PlaceStanding[]) => {
      const nav = markNav(group, standings);
      if (nav) goToPackage(...nav);
    },
    [goToPackage],
  );

  return (
    <>
      <MarksNote />
      {rows.some((row) => anyCustomized(row.standings)) ? (
        <LibraryLegend />
      ) : null}
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Name</TableHead>
            <TableHead>Type</TableHead>
            <TableHead>{TAGS_ROW_LABEL}</TableHead>
            <TableHead>Harnesses</TableHead>
            <TableHead>Where</TableHead>
            <TableHead>From</TableHead>
            <TableHead className="text-right">Updated</TableHead>
            <TableHead>Status</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map(({ group, standings, origin }) => (
            <InstalledRow
              key={group.key}
              group={group}
              origin={origin}
              originError={originError}
              standings={standings}
              onOpen={openRow}
              onOpenPlace={openMark}
            />
          ))}
          {scanning ? <InstalledSkeleton /> : null}
          {!scanning && groups.length === 0 ? (
            <TableEmptyRow
              hasAnyItems={hasAnyItems}
              onClearFilters={onClearFilters}
              onBrowse={onBrowse}
            />
          ) : null}
        </TableBody>
      </Table>
    </>
  );
}
