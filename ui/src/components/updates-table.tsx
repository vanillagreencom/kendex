import { MoreHorizontal } from "lucide-react";
import type { UpdateRow } from "@/bindings";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Switch } from "@/components/ui/switch";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  AUTO_UPDATE_COLUMN,
  autoUpdateLabel,
  EDITED_UPDATE_TAG,
  IGNORE_UPDATES_LABEL,
  NOTIFY_AGAIN_LABEL,
  PINNED_UPDATE_TAG,
  PREVIEW_CHANGES_LABEL,
  REMOVED_UPSTREAM_TAG,
  UPDATE_LABEL,
  UPDATES_NAME_COLUMN,
  UPDATES_TYPE_COLUMN,
  UPDATES_VERSION_COLUMN,
} from "@/lib/copy";
import { kindIcon } from "@/lib/kind-icon";
import { kindLabel, packageDisplayName } from "@/lib/labels";
import { versionLabel } from "@/lib/versions";
import { useNavStore } from "@/stores/nav";
import { useUpdatesStore } from "@/stores/updates";

/** Pending updates as one table, so the column headers say what the
 *  toggle and the buttons do once instead of every row repeating it.
 *  Callers render nothing for an empty list — a header over no rows
 *  would promise content that is not there. */
export function UpdatesTable({
  rows,
  onIgnore,
}: {
  rows: UpdateRow[];
  /** Absent for muted rows: their only extra action is "notify again". */
  onIgnore?: (row: UpdateRow) => void;
}) {
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>{UPDATES_NAME_COLUMN}</TableHead>
          <TableHead className="w-28">{UPDATES_TYPE_COLUMN}</TableHead>
          <TableHead className="w-44">{UPDATES_VERSION_COLUMN}</TableHead>
          <TableHead className="w-28 text-center">
            {AUTO_UPDATE_COLUMN}
          </TableHead>
          <TableHead className="w-64">
            <span className="sr-only">Actions</span>
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {rows.map((row) => (
          <UpdateTableRow
            key={`${row.kind}:${row.name}:${JSON.stringify(row.scope)}`}
            row={row}
            onIgnore={onIgnore}
          />
        ))}
      </TableBody>
    </Table>
  );
}

function UpdateTableRow({
  row,
  onIgnore,
}: {
  row: UpdateRow;
  onIgnore?: (row: UpdateRow) => void;
}) {
  const { busy, updateOne, setAutoUpdate, setIgnored } = useUpdatesStore();
  const goToPackage = useNavStore((s) => s.goToPackage);
  const Icon = kindIcon(row.kind);
  const name = packageDisplayName(row);

  const preview = () => {
    if (!row.current || !row.latest) return;
    goToPackage(
      { kind: row.kind, name: row.name, scope: row.scope },
      { mode: "diff", from: row.current.commit, to: row.latest.commit },
    );
  };

  return (
    <TableRow>
      <TableCell>
        <div className="flex min-w-0 items-center gap-2.5">
          <Icon className="size-4 shrink-0 text-muted-foreground" />
          <span className="truncate font-medium">{name}</span>
          {row.pinned ? (
            <Badge variant="outline">{PINNED_UPDATE_TAG}</Badge>
          ) : null}
          {row.blockedByLocalEdit ? (
            <Badge variant="outline">{EDITED_UPDATE_TAG}</Badge>
          ) : null}
          {row.removedUpstream ? (
            <Badge variant="outline">{REMOVED_UPSTREAM_TAG}</Badge>
          ) : null}
        </div>
      </TableCell>
      <TableCell className="text-muted-foreground">
        {kindLabel(row.kind)}
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
              aria-label={autoUpdateLabel(name)}
              checked={!row.pinned}
              disabled={busy}
              onCheckedChange={(auto) => void setAutoUpdate(row, auto)}
            />
          </TableCell>
          <TableCell>
            <div className="flex items-center justify-end gap-1.5">
              <Button
                size="sm"
                variant="ghost"
                className="text-muted-foreground"
                onClick={preview}
              >
                {PREVIEW_CHANGES_LABEL}
              </Button>
              <Button
                size="sm"
                variant="outline"
                disabled={
                  busy || row.blockedByLocalEdit || !row.updateAvailable
                }
                onClick={() => void updateOne(row)}
              >
                {UPDATE_LABEL}
              </Button>
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
    </TableRow>
  );
}
