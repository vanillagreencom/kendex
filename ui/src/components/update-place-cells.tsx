import { MoreHorizontal } from "lucide-react";
import type { Scope, UpdateRow } from "@/bindings";
import {
  InstallAsNew,
  installableBeside,
} from "@/components/install-as-new-button";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { TableCell } from "@/components/ui/table";
import { IGNORE_UPDATES_LABEL, NOTIFY_AGAIN_LABEL } from "@/lib/copy";
import {
  EDITED_CANT_UPDATE_NOTE,
  OPEN_PACKAGE_LABEL,
  openPlaceLabel,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATE_REVIEW_LABEL,
  UPDATES_ONE_AT_A_TIME_NOTE,
} from "@/lib/copy-updates";
import { selectionOf } from "@/lib/derive";
import { canUpdatePlace, placeName, updateWithheld } from "@/lib/update-groups";
import { readUnsettled } from "@/lib/updates-read-state";
import { versionLabel } from "@/lib/versions";
import { useNavStore } from "@/stores/nav";
import type { PackageRef } from "@/stores/nav-types";
import { useUpdatesStore } from "@/stores/updates";
import { useUpdatesView } from "@/stores/updates-view";

/** The cells that belong to one place: where it is, its versions when the
 *  table shows them, and what can be done about it here. A package out of
 *  date in one place shows these on its own row; one out of date in several
 *  shows them once per place under the package.
 *
 *  Where the place is named it opens that place, on the rule the app follows
 *  everywhere: a row, card or chip naming a thing opens it. */
export function PlaceCells({
  row,
  among,
  onIgnore,
  onUpdate,
}: {
  row: UpdateRow;
  /** The package's other places, so two same-named folders read apart. */
  among: Scope[];
  onIgnore?: (row: UpdateRow) => void;
  /** Open the one update flow on this place. Absent for muted rows, whose
   *  only action is "notify again". */
  onUpdate?: (row: UpdateRow) => void;
}) {
  const { busy, setIgnored } = useUpdatesStore();
  // A read about to replace these rows holds this row's controls; the
  // store refuses regardless, and they say so rather than invite a click.
  const held = useUpdatesStore(readUnsettled);
  // The mute sends no value read off the row, so `held` is not its bar.
  // What bars it is the exact pair the store refuses on: a check out whose
  // report predates this commit, or another write already running.
  const checking = useUpdatesStore((s) => s.checking);
  const oneAtATime = busy || checking;
  const showVersion = useUpdatesView((s) => s.showVersion);
  const goToPackage = useNavStore((s) => s.goToPackage);
  const goToLibrary = useNavStore((s) => s.goToLibrary);
  const place = placeName(row.scope, among);
  // What stands in the way of this row's update, if anything — one
  // reading, the same the dialog's own offer acts on.
  const withheld = updateWithheld(row);
  // An update row comes from the install records, so it names a package
  // they account for.
  const ref: PackageRef = {
    kind: row.kind,
    name: row.name,
    scope: row.scope,
    identity: "recorded",
  };

  return (
    <>
      <TableCell
        className="text-muted-foreground"
        title={row.scope.scope === "project" ? row.scope.root : undefined}
      >
        <button
          type="button"
          className="hover:text-foreground hover:underline"
          aria-label={openPlaceLabel(place)}
          onClick={() => goToLibrary({ scope: selectionOf(row.scope) })}
        >
          {place}
        </button>
      </TableCell>
      {showVersion ? (
        <TableCell className="font-mono text-xs text-muted-foreground">
          {row.current ? versionLabel(row.current) : "?"} →{" "}
          {row.latest ? versionLabel(row.latest) : "?"}
        </TableCell>
      ) : null}
      {row.ignored ? (
        <TableCell className="text-right">
          <Button
            size="sm"
            variant="outline"
            disabled={oneAtATime}
            title={oneAtATime ? UPDATES_ONE_AT_A_TIME_NOTE : undefined}
            onClick={() => void setIgnored(row, false)}
          >
            {NOTIFY_AGAIN_LABEL}
          </Button>
        </TableCell>
      ) : (
        <TableCell>
          {/* The edited note sits above the controls: beside them, the row
              would not fit the app's default window. */}
          <div className="flex flex-col items-end gap-1">
            {row.blockedByLocalEdit ? (
              <span className="text-xs text-muted-foreground">
                {EDITED_CANT_UPDATE_NOTE}
              </span>
            ) : null}
            <div className="flex items-center justify-end gap-1.5">
              {row.blockedByLocalEdit ? (
                <>
                  {/* No update to review and nothing to install beside: the
                      fork-or-discard choice on the package page is what is
                      left, and this is the way there. */}
                  <Button
                    size="sm"
                    variant="ghost"
                    className="text-muted-foreground"
                    onClick={() => goToPackage(ref)}
                  >
                    {OPEN_PACKAGE_LABEL}
                  </Button>
                  {installableBeside(row) ? (
                    <InstallAsNew row={row} busy={busy} held={held} />
                  ) : null}
                </>
              ) : onUpdate ? (
                <Button
                  size="sm"
                  variant="outline"
                  disabled={busy || held || !canUpdatePlace(row)}
                  // The row's own reasons come from `updateWithheld`, the
                  // reading every surface shares; `held` is this surface's
                  // alone, because only its actions send a value read off
                  // the row.
                  title={
                    withheld ?? (held ? UPDATE_NEEDS_CHECK_NOTE : undefined)
                  }
                  onClick={() => onUpdate(row)}
                >
                  {UPDATE_REVIEW_LABEL}
                </Button>
              ) : null}
              {onIgnore ? (
                <DropdownMenu>
                  <DropdownMenuTrigger
                    render={
                      <Button
                        size="icon-xs"
                        variant="ghost"
                        aria-label="More actions"
                      >
                        <MoreHorizontal className="size-4" />
                      </Button>
                    }
                  />
                  <DropdownMenuContent align="end">
                    <DropdownMenuItem
                      disabled={oneAtATime}
                      onClick={() => onIgnore(row)}
                    >
                      {IGNORE_UPDATES_LABEL}
                    </DropdownMenuItem>
                  </DropdownMenuContent>
                </DropdownMenu>
              ) : null}
            </div>
          </div>
        </TableCell>
      )}
    </>
  );
}
