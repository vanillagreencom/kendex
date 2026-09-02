import { useEffect, useState } from "react";
import { commands, type Scope, type UnsubscribePreview } from "@/bindings";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { kindLabel, scopeName } from "@/lib/labels";
import { cn } from "@/lib/utils";
import { useMarketplacesStore } from "@/stores/marketplaces";

/** §4.3's choice: leaving a marketplace either uninstalls what came from it
 * or keeps it as the user's own. Nothing installed makes it a plain confirm,
 * and an edited package pauses the whole thing until it is decided. */
export function UnsubscribeDialog({
  open,
  onOpenChange,
  scope,
  source,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  scope: Scope;
  source: string;
}) {
  const unsubscribe = useMarketplacesStore((s) => s.unsubscribe);
  const busy = useMarketplacesStore((s) => s.busy);
  // The read can fail underneath an open dialog, leaving this one named
  // from rows nobody could confirm. It confirms anyway: the engine has the
  // manifest and refuses a source that is not there, which the dialog then
  // shows in place of the success.
  const [preview, setPreview] = useState<UnsubscribePreview | null>(null);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [keep, setKeep] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    setPreview(null);
    setPreviewError(null);
    setError(null);
    void commands.marketplaceUnsubscribePreview(scope, source).then((r) => {
      if (r.status === "ok") setPreview(r.data);
      else setPreviewError(r.error);
    });
  }, [open, scope, source]);

  const installed = preview
    ? preview.removable.length + preview.edited.length
    : 0;
  const parts: string[] = [];
  if (preview && installed > 0)
    parts.push(`${installed} package${installed === 1 ? "" : "s"}`);
  if (preview && preview.bundles.length > 0)
    parts.push(
      `${preview.bundles.length} bundle${preview.bundles.length === 1 ? "" : "s"}`,
    );
  const hasEdited = (preview?.edited.length ?? 0) > 0;

  const confirm = () => {
    // The refusal comes back from the call, never out of the store's shared
    // slot: every landing overview read clears that slot, so one arriving in
    // the gap would leave this dialog open with an empty error area and no
    // account of why nothing happened.
    void unsubscribe(scope, source, installed > 0 && keep, false).then(
      (outcome) => {
        if ("error" in outcome) setError(outcome.error);
        else onOpenChange(false);
      },
    );
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Unsubscribe from {source}?</DialogTitle>
          {preview && installed > 0 ? (
            <DialogDescription>
              {parts.join(" and ")} installed from it ({scopeName(scope)}).
            </DialogDescription>
          ) : preview ? (
            <DialogDescription>
              Nothing is installed from it — unsubscribing just removes the
              subscription.
            </DialogDescription>
          ) : null}
        </DialogHeader>

        {previewError ? (
          <p className="text-sm text-critical" role="alert">
            {previewError}
          </p>
        ) : null}

        {preview && installed > 0 ? (
          <div className="space-y-2">
            <Choice
              checked={!keep}
              onSelect={() => setKeep(false)}
              disabled={hasEdited}
              title="Remove them"
              detail={`Uninstall all ${installed}, keep nothing.`}
            />
            <Choice
              checked={keep}
              onSelect={() => setKeep(true)}
              disabled={hasEdited}
              title="Keep them as my own"
              detail={`They stay installed as they are, stop receiving updates, and show under "Your own" in My Library.`}
            />
          </div>
        ) : null}

        {hasEdited && preview ? (
          <div className="rounded-md border border-warning/40 bg-warning/10 p-3 text-sm">
            <p className="font-medium">
              You've edited{" "}
              {preview.edited
                .map(
                  ({ kind, name }) =>
                    `${kindLabel(kind).toLowerCase()} ${name}`,
                )
                .join(", ")}
              .
            </p>
            <p className="mt-1 text-muted-foreground">
              Unsubscribing waits until each edited package is kept as a fork or
              its edits are discarded — open it in My Library to decide.
            </p>
          </div>
        ) : null}

        {error ? (
          <p className="text-sm text-critical" role="alert">
            {error}
          </p>
        ) : null}

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            variant="destructive"
            disabled={busy || !preview || hasEdited}
            onClick={confirm}
          >
            {busy ? "Unsubscribing…" : "Unsubscribe"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** One of the two ways out, as a big clickable radio row. */
function Choice({
  checked,
  onSelect,
  disabled,
  title,
  detail,
}: {
  checked: boolean;
  onSelect: () => void;
  disabled?: boolean;
  title: string;
  detail: string;
}) {
  return (
    <Label
      className={cn(
        "flex cursor-pointer items-start gap-3 rounded-md border p-3",
        checked && "border-foreground/40 bg-accent/40",
        disabled && "cursor-not-allowed opacity-60",
      )}
    >
      <input
        type="radio"
        className="mt-1 accent-foreground"
        checked={checked}
        disabled={disabled}
        onChange={onSelect}
      />
      <span className="space-y-0.5">
        <span className="block text-sm font-medium">{title}</span>
        <span className="block text-xs leading-relaxed text-muted-foreground">
          {detail}
        </span>
      </span>
    </Label>
  );
}
