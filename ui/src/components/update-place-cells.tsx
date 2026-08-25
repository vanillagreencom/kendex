import { MoreHorizontal } from "lucide-react";
import { useState } from "react";
import type { Scope, UpdateRow } from "@/bindings";
import { InstallAsNewDialog } from "@/components/install-as-new-dialog";
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
  INSTALL_AS_NEW_LABEL,
  UPDATE_NEEDS_CHECK_NOTE,
} from "@/lib/copy-updates";
import { packageDisplayName } from "@/lib/labels";
import { heldByOwner, placeName, switchLockedBy } from "@/lib/update-groups";
import { versionLabel } from "@/lib/versions";
import { useNavStore } from "@/stores/nav";
import { useUpdatesStore } from "@/stores/updates";

/** The cells that belong to one place: where it is, its versions when the
 *  table shows them, whether it follows its source, and what can be done
 *  about it here. A package installed in one place shows these on its own
 *  row; one installed in several shows them once per place under the
 *  package. */
export function PlaceCells({
  row,
  among,
  onIgnore,
  showVersion = false,
}: {
  row: UpdateRow;
  /** The package's other places, so two same-named folders read apart. */
  among: Scope[];
  onIgnore?: (row: UpdateRow) => void;
  /** Whether the Version cell — commit ids — is drawn. */
  showVersion?: boolean;
}) {
  const {
    busy,
    loaded,
    checking,
    overviewInFlight,
    updateOne,
    setAutoUpdate,
    setIgnored,
  } = useUpdatesStore();
  // Anything overview-producing in flight is about to replace these rows;
  // the store actions refuse regardless, and the controls say so instead
  // of inviting the click.
  const held = !loaded || checking || overviewInFlight;
  const goToPackage = useNavStore((s) => s.goToPackage);
  const name = packageDisplayName(row);
  const place = placeName(row.scope, among);
  const locked = switchLockedBy(row);

  const preview = () => {
    if (!row.current || !row.latest) return;
    goToPackage(
      { kind: row.kind, name: row.name, scope: row.scope },
      { mode: "diff", from: row.current.commit, to: row.latest.commit },
    );
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
                <Button
                  size="sm"
                  variant="ghost"
                  className="text-muted-foreground"
                  onClick={preview}
                >
                  {PREVIEW_CHANGES_LABEL}
                </Button>
                {row.blockedByLocalEdit ? (
                  <InstallAsNew row={row} busy={busy} held={held} />
                ) : (
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={
                      busy || held || !row.updateAvailable || heldByOwner(row)
                    }
                    title={
                      heldByOwner(row)
                        ? HELD_BY_OWNER_NOTE
                        : held
                          ? UPDATE_NEEDS_CHECK_NOTE
                          : undefined
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
                      <DropdownMenuItem onClick={() => onIgnore(row)}>
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

/** The edited place's one way to a newer version: beside the edits, never
 *  over them. Offered only where the engine can keep the edited rendering
 *  — a bundle member, an edit spread over several tools, or a tool whose
 *  format cannot be read back settles on the package page instead. The
 *  install may move a hold to the row's `latest`, so it waits for a check
 *  the same as Update. */
function InstallAsNew({
  row,
  busy,
  held,
}: {
  row: UpdateRow;
  busy: boolean;
  held: boolean;
}) {
  const [open, setOpen] = useState(false);
  const harness = row.forkableHarness;
  if (!harness) return null;
  return (
    <>
      <Button
        size="sm"
        variant="outline"
        disabled={busy || held}
        title={held ? UPDATE_NEEDS_CHECK_NOTE : undefined}
        onClick={() => setOpen(true)}
      >
        {INSTALL_AS_NEW_LABEL}
      </Button>
      {open ? (
        <InstallAsNewDialog
          row={row}
          harness={harness}
          onOpenChange={setOpen}
        />
      ) : null}
    </>
  );
}
