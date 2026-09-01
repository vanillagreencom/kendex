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
import { Switch } from "@/components/ui/switch";
import { TableCell } from "@/components/ui/table";
import {
  IGNORE_UPDATES_LABEL,
  NOTIFY_AGAIN_LABEL,
  PREVIEW_CHANGES_LABEL,
  UPDATE_LABEL,
} from "@/lib/copy";
import {
  EDITED_CANT_UPDATE_NOTE,
  followSourceLabel,
  HELD_BY_OWNER_NOTE,
  heldBySourceNote,
  OPEN_PACKAGE_LABEL,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATES_ONE_AT_A_TIME_NOTE,
} from "@/lib/copy-updates";
import { packageDisplayName } from "@/lib/labels";
import {
  canUpdatePlace,
  placeName,
  switchLockedBy,
  updateWithheld,
} from "@/lib/update-groups";
import { rowUnsettled } from "@/lib/updates-read-state";
import { versionLabel } from "@/lib/versions";
import { useNavStore } from "@/stores/nav";
import { useUpdatesStore } from "@/stores/updates";
import { useUpdatesView } from "@/stores/updates-view";

/** The cells that belong to one place: where it is, its versions when the
 *  table shows them, whether it follows its source, and what can be done
 *  about it here. A package installed in one place shows these on its own
 *  row; one installed in several shows them once per place under the
 *  package. */
export function PlaceCells({
  row,
  among,
  onIgnore,
}: {
  row: UpdateRow;
  /** The package's other places, so two same-named folders read apart. */
  among: Scope[];
  onIgnore?: (row: UpdateRow) => void;
}) {
  const { busy, updateOne, setAutoUpdate, setIgnored } = useUpdatesStore();
  // Anything about to replace this place's row — an overview-producing
  // read, a follow switch settling in its scope — holds its controls; the
  // store refuses regardless, and they say so rather than invite a click.
  const held = useUpdatesStore((s) => rowUnsettled(s, row));
  // The mute sends no value read off the row, so `held` is not its bar.
  // What bars it is the exact pair the store refuses on: a check out whose
  // report predates this commit, or another write already running.
  const checking = useUpdatesStore((s) => s.checking);
  const oneAtATime = busy || checking;
  const showVersion = useUpdatesView((s) => s.showVersion);
  const goToPackage = useNavStore((s) => s.goToPackage);
  const name = packageDisplayName(row);
  const place = placeName(row.scope, among);
  const locked = switchLockedBy(row);
  // What stands in the way of this row's Update, if anything — one
  // reading, the same "Update all" acts on, ordered where it is defined.
  const withheld = updateWithheld(row);
  const ref = { kind: row.kind, name: row.name, scope: row.scope };

  const preview = () => {
    if (!row.current || !row.latest) return;
    goToPackage(ref, {
      mode: "diff",
      from: row.current.commit,
      to: row.latest.commit,
    });
  };

  return (
    <>
      <TableCell
        className="text-muted-foreground"
        title={row.scope.scope === "project" ? row.scope.root : undefined}
      >
        {place}
      </TableCell>
      {showVersion ? (
        <TableCell className="font-mono text-xs text-muted-foreground">
          {row.current ? versionLabel(row.current) : "?"} →{" "}
          {row.latest ? versionLabel(row.latest) : "?"}
        </TableCell>
      ) : null}
      {row.ignored ? (
        <TableCell colSpan={2} className="text-right">
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
        <>
          <TableCell className="text-center">
            {/* Switching follow OFF holds the package at row.current's
                commit — from a stale row that pins it to an old version,
                so the switch waits for a check the same as Update. */}
            <Switch
              aria-label={followSourceLabel(name, place)}
              checked={!row.pinned}
              disabled={busy || held || locked !== null}
              title={
                locked?.kind === "source"
                  ? heldBySourceNote(locked.name)
                  : locked
                    ? HELD_BY_OWNER_NOTE
                    : held
                      ? UPDATE_NEEDS_CHECK_NOTE
                      : undefined
              }
              onCheckedChange={(follow) => void setAutoUpdate(row, follow)}
            />
          </TableCell>
          <TableCell>
            {/* The edited note sits above the controls: beside them, the
                row would not fit the app's default window. */}
            <div className="flex flex-col items-end gap-1">
              {row.blockedByLocalEdit ? (
                <span className="text-xs text-muted-foreground">
                  {EDITED_CANT_UPDATE_NOTE}
                </span>
              ) : null}
              <div className="flex items-center justify-end gap-1.5">
                {row.current && row.latest ? (
                  <Button
                    size="sm"
                    variant="ghost"
                    className="text-muted-foreground"
                    onClick={preview}
                  >
                    {PREVIEW_CHANGES_LABEL}
                  </Button>
                ) : row.blockedByLocalEdit ? (
                  // No versions to compare, nothing to install beside: the
                  // fork-or-discard choice on the package page is what is
                  // left, and this is the way there.
                  <Button
                    size="sm"
                    variant="ghost"
                    className="text-muted-foreground"
                    onClick={() => goToPackage(ref)}
                  >
                    {OPEN_PACKAGE_LABEL}
                  </Button>
                ) : null}
                {row.blockedByLocalEdit ? (
                  installableBeside(row) ? (
                    <InstallAsNew row={row} busy={busy} held={held} />
                  ) : null
                ) : (
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={busy || held || !canUpdatePlace(row)}
                    // The row's own reasons rank as `pageUpdateWithheld`
                    // states; `held` is this surface's alone, because
                    // only its actions send a value read off the row.
                    title={
                      withheld ?? (held ? UPDATE_NEEDS_CHECK_NOTE : undefined)
                    }
                    onClick={() => void updateOne(row)}
                  >
                    {UPDATE_LABEL}
                  </Button>
                )}
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
        </>
      )}
    </>
  );
}
