import { MoreHorizontal } from "lucide-react";
import type { Scope, UpdateRow } from "@/bindings";
import { CustomizedActions } from "@/components/customized-actions";
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
import { followSourceLabel, HELD_BY_OWNER_NOTE } from "@/lib/copy-updates";
import { packageDisplayName } from "@/lib/labels";
import { heldByOwner, placeName } from "@/lib/update-groups";
import { versionLabel } from "@/lib/versions";
import { useNavStore } from "@/stores/nav";
import { useUpdatesStore } from "@/stores/updates";

/** The cells that belong to one place: where it is, its versions, whether
 *  it follows its source, and what can be done about it here. A package
 *  installed in one place shows these on its own row; one installed in
 *  several shows them once per place under the package. */
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
  const goToPackage = useNavStore((s) => s.goToPackage);
  const name = packageDisplayName(row);
  const place = placeName(row.scope, among);

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
      <TableCell className="font-mono text-xs text-muted-foreground">
        {row.current ? versionLabel(row.current) : "?"} →{" "}
        {row.latest ? versionLabel(row.latest) : "?"}
      </TableCell>
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
            <Switch
              aria-label={followSourceLabel(name, place)}
              checked={!row.pinned}
              disabled={busy || row.derived}
              title={row.derived ? HELD_BY_OWNER_NOTE : undefined}
              onCheckedChange={(follow) => void setAutoUpdate(row, follow)}
            />
          </TableCell>
          <TableCell>
            <div className="flex items-center justify-end gap-1.5">
              {row.blockedByLocalEdit ? (
                <CustomizedActions row={row} busy={busy} />
              ) : null}
              <Button
                size="sm"
                variant="ghost"
                className="text-muted-foreground"
                onClick={preview}
              >
                {PREVIEW_CHANGES_LABEL}
              </Button>
              {row.blockedByLocalEdit ? null : (
                <Button
                  size="sm"
                  variant="outline"
                  disabled={busy || !row.updateAvailable || heldByOwner(row)}
                  title={heldByOwner(row) ? HELD_BY_OWNER_NOTE : undefined}
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
          </TableCell>
        </>
      )}
    </>
  );
}
