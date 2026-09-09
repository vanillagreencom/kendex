import type { Scope } from "@/bindings";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { installedInCount, installedInLabel } from "@/lib/copy-marketplaces";
import { selectionOf } from "@/lib/derive";
import { scopeNames, scopePath } from "@/lib/labels";
import { useNavStore } from "@/stores/nav";

/** Where a package or a curated set is installed, as the one control that
 *  opens those places. A marketplace page says which places hold what it
 *  offers and manages none of them: the click opens the place, and what
 *  that place does with the package is settled there.
 *
 *  The places are counted by what they are — `lib/place-word.ts` — so the
 *  personal setup is never counted as a project, and the menu names it as
 *  Personal beside every project holding the same package.
 *
 *  Nothing at all where it is installed nowhere. A count of zero is not a
 *  fact worth a control, and the row or card already says the package is
 *  available rather than installed. */
export function InstalledIn({
  places,
  /** Whether the count carries the verb itself. A table column heads the
   *  cells with "Installed in" once, so the cell says only how many; a card
   *  stands alone and says the whole thing. The accessible name is the whole
   *  thing either way — a screen reader reaching the control has not read
   *  the column head beside it. */
  standalone,
}: {
  places: Scope[];
  standalone?: boolean;
}) {
  const goToLibrary = useNavStore((s) => s.goToLibrary);
  if (places.length === 0) return null;
  // Named against each other, not one at a time: two registered projects
  // can end in the same folder, and an item labelled "kendex" beside
  // another labelled "kendex" names neither, over a link that opens one of
  // them. Where a basename is shared, [scopeNames] substitutes the path.
  const named = scopeNames(places);

  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <button
            type="button"
            className="cursor-pointer truncate text-left underline underline-offset-2 hover:text-foreground"
            aria-label={installedInLabel(places)}
          >
            {standalone ? installedInLabel(places) : installedInCount(places)}
          </button>
        }
      />
      <DropdownMenuContent align="start">
        {places.map((scope, index) => (
          <DropdownMenuItem
            key={scopePath(scope) ?? "global"}
            onClick={() => goToLibrary({ scope: selectionOf(scope) })}
          >
            {named[index]}
          </DropdownMenuItem>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
