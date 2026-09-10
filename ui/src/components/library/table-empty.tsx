import { Button } from "@/components/ui/button";
import { TableCell, TableRow } from "@/components/ui/table";
import {
  ADD_PACKAGES_HELP,
  addPackagesTo,
  nothingInstalledIn,
} from "@/lib/copy-install";

/** The Installed table with no rows to show.
 *
 *  Narrowed to one place with nothing in it, the way out is to install
 *  something there — the same offer that place's own card makes, said here
 *  because this is where the reader is looking. Narrowed some other way, a
 *  filter is what is hiding the rows and clearing it is the way out. An
 *  empty library with no narrowing at all points at Marketplaces. */
export function TableEmptyRow({
  hasAnyItems,
  place,
  onClearFilters,
  onBrowse,
  onAddPackages,
}: {
  hasAnyItems: boolean;
  /** The one place this table is narrowed to, and what it is called, where
   *  it is narrowed to one. Null for every wider view — including the
   *  machine-wide one, which is not a place a package installs into. */
  place: string | null;
  onClearFilters: () => void;
  onBrowse: () => void;
  onAddPackages: () => void;
}) {
  return (
    <TableRow>
      <TableCell colSpan={8} className="py-10">
        {place !== null ? (
          <div className="flex flex-col items-center gap-3 text-center">
            <div>
              <p className="font-medium">{nothingInstalledIn(place)}</p>
              <p className="text-sm text-muted-foreground">
                {ADD_PACKAGES_HELP}
              </p>
            </div>
            <Button variant="outline" size="sm" onClick={onAddPackages}>
              {addPackagesTo(place)}
            </Button>
          </div>
        ) : hasAnyItems ? (
          <div className="flex flex-col items-center gap-3 text-center">
            <div>
              <p className="font-medium">Nothing matches</p>
              <p className="text-sm text-muted-foreground">
                Try a different search or filter.
              </p>
            </div>
            <Button variant="outline" size="sm" onClick={onClearFilters}>
              Clear filters
            </Button>
          </div>
        ) : (
          <div className="flex flex-col items-center gap-3 text-center">
            <div>
              <p className="font-medium">Nothing installed yet</p>
              <p className="text-sm text-muted-foreground">
                Browse Marketplaces to install skills, agents and more.
              </p>
            </div>
            <Button variant="outline" size="sm" onClick={onBrowse}>
              Browse Marketplaces
            </Button>
          </div>
        )}
      </TableCell>
    </TableRow>
  );
}
