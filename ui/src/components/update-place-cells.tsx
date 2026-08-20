import { MoreHorizontal } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";
import { commands, type UpdateRow } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
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
  CUSTOMIZED_HERE_LABEL,
  DISCARD_EDITS_CONFIRM_BODY,
  DISCARD_EDITS_CONFIRM_LABEL,
  DISCARD_EDITS_CONFIRM_TITLE,
  FORK_ERROR_TITLE,
  followSourceLabel,
  forkedToastLabel,
  IGNORE_UPDATES_LABEL,
  KEEP_AS_FORK_LABEL,
  NOTIFY_AGAIN_LABEL,
  PREVIEW_CHANGES_LABEL,
  UPDATE_LABEL,
  USE_NEW_VERSION_LABEL,
} from "@/lib/copy";
import { packageDisplayName } from "@/lib/labels";
import { sameScope, scopeKey } from "@/lib/scope";
import { placeName } from "@/lib/update-groups";
import { versionLabel } from "@/lib/versions";
import { useAuditStore } from "@/stores/audit";
import { useNavStore } from "@/stores/nav";
import { useProblemsStore } from "@/stores/problems";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";

/** The cells that belong to one place: where it is, its versions, whether
 *  it follows its source, and what can be done about it here. A package
 *  installed in one place shows these on its own row; one installed in
 *  several shows them once per place under the package. */
export function PlaceCells({
  row,
  onIgnore,
}: {
  row: UpdateRow;
  onIgnore?: (row: UpdateRow) => void;
}) {
  const { busy, updateOne, setAutoUpdate, setIgnored } = useUpdatesStore();
  const goToPackage = useNavStore((s) => s.goToPackage);
  const name = packageDisplayName(row);
  const place = placeName(row.scope);

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
              disabled={busy}
              onCheckedChange={(follow) => void setAutoUpdate(row, follow)}
            />
          </TableCell>
          <TableCell>
            <div className="flex items-center justify-end gap-1.5">
              {row.blockedByLocalEdit ? <CustomizedActions row={row} /> : null}
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
                  disabled={busy || !row.updateAvailable}
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

/** A place whose files were edited by hand: the update waits on a
 *  decision, made here per place because an edit in one project says
 *  nothing about the copy in another. */
function CustomizedActions({ row }: { row: UpdateRow }) {
  const showError = useProblemsStore((s) => s.showError);
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  const [busy, setBusy] = useState(false);
  // Forking captures one rendering's bytes, so it needs the harness the
  // edited install belongs to — the scan knows which one that is.
  const harness = useScanStore(
    (s) =>
      s.result?.items.find(
        (item) =>
          item.kind === row.kind &&
          item.name === row.name &&
          sameScope(item.scope, row.scope),
      )?.harness ?? null,
  );

  const refreshAll = async () => {
    await useScanStore.getState().refresh();
    await useAuditStore.getState().refresh({ force: true });
    await useUpdatesStore.getState().load();
  };

  const keepAsOwn = async () => {
    if (!harness) return;
    setBusy(true);
    const response = await commands.packageFork(
      row.scope,
      row.kind,
      row.name,
      harness,
    );
    setBusy(false);
    if (response.status === "error") {
      showError({ title: FORK_ERROR_TITLE, message: response.error });
      return;
    }
    toast.success(forkedToastLabel(packageDisplayName(row)));
    await refreshAll();
  };

  const discardEdits = async () => {
    setBusy(true);
    const response = await commands.applyDiscardEdits(
      row.scope,
      row.kind,
      row.name,
    );
    setBusy(false);
    setConfirmDiscard(false);
    if (response.status === "error") {
      showError({ title: FORK_ERROR_TITLE, message: response.error });
      return;
    }
    await refreshAll();
  };

  return (
    <>
      <span className="mr-1 text-xs text-warning">{CUSTOMIZED_HERE_LABEL}</span>
      <Button
        size="sm"
        variant="outline"
        disabled={busy || harness === null}
        onClick={() => void keepAsOwn()}
      >
        {KEEP_AS_FORK_LABEL}
      </Button>
      <Button
        size="sm"
        variant="outline"
        disabled={busy}
        onClick={() => setConfirmDiscard(true)}
      >
        {USE_NEW_VERSION_LABEL}
      </Button>
      <ConfirmDialog
        key={scopeKey(row.scope)}
        open={confirmDiscard}
        onOpenChange={setConfirmDiscard}
        title={DISCARD_EDITS_CONFIRM_TITLE}
        description={DISCARD_EDITS_CONFIRM_BODY}
        confirmLabel={DISCARD_EDITS_CONFIRM_LABEL}
        destructive
        busy={busy}
        onConfirm={() => void discardEdits()}
      />
    </>
  );
}
