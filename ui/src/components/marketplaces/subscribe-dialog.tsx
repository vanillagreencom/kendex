import { useEffect, useState } from "react";
import { commands, type Scope } from "@/bindings";
import { RecordsUnreadableWriteNote } from "@/components/marketplaces/packages-trouble";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { SUBSCRIBE_MEANS } from "@/lib/copy-marketplaces";
import { scopeLabel } from "@/lib/derive";
import { scopeName } from "@/lib/labels";
import { everyPlace } from "@/lib/scope";
import { useOrderedRead } from "@/lib/use-ordered-read";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useSettingsStore } from "@/stores/settings";
import { projectsOf } from "@/stores/settings-projects";

/** Subscribing points kendex at a marketplace: a repo shorthand, a git or
 * GitHub tree URL, a skills.sh package URL, or a local folder. Defaults to
 * Personal — a project subscription is the exception, not the first ask. */
export function SubscribeDialog({
  open,
  onOpenChange,
  initialReference = "",
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** Pre-filled from a Community row's Subscribe button. */
  initialReference?: string;
}) {
  const subscribe = useMarketplacesStore((s) => s.subscribe);
  const busy = useMarketplacesStore((s) => s.busy);
  const projects = useSettingsStore(projectsOf);
  const [reference, setReference] = useState(initialReference);
  const [name, setName] = useState("");
  const [where, setWhere] = useState("global");

  // The refusal this dialog shows is its own, held here and set from what
  // `subscribe` handed back. The store's shared `error` is written by every
  // marketplaces action and cleared by `load` on each landing overview
  // read, so rendering it meant a read finishing under an open dialog wiped
  // the refusal off the screen — dialog open, input intact, no account of
  // why nothing happened. UnsubscribeDialog already keeps its own for the
  // same reason.
  const [error, setError] = useState<string | null>(null);
  // The page mounts this dialog permanently, so each opening starts clean
  // rather than showing the refusal of an attempt the person cancelled.
  // `clearError` empties the shared slot alongside it: nothing renders that
  // slot any more, and leaving a stale message in it would mislead the next
  // reader of the store.
  const clearError = useMarketplacesStore((s) => s.clearError);
  useEffect(() => {
    if (open) {
      setError(null);
      clearError();
    }
  }, [open, clearError]);

  const scopes = everyPlace(projects);
  const target: Scope = scopes.find((s) => scopeLabel(s) === where) ?? {
    scope: "global",
  };

  // Subscribing plans against the chosen place's lock, so a record this
  // build can't read refuses the write outright. Asked of the place that
  // was chosen and re-asked when the choice moves: the answer belongs to
  // the place, not to this dialog, and the reason has to travel with the
  // choice that caused it rather than arriving as the engine's raw refusal
  // after the press.
  const records = useOrderedRead<boolean>(
    open ? scopeLabel(target) : null,
    () => commands.scopeRecordsUnreadable(target),
  );
  // The answer, and the button's own question. Subscribe is withheld while
  // the read is still out too, since a press then lands before the place
  // has answered; only an answered read draws the reason, because a
  // sub-millisecond wait has nothing to say. A failed read is left open:
  // the engine refuses the write itself, and failing closed here would
  // disable Subscribe for good whenever the local read errors.
  const unreadable = records.status === "ok" && records.data;
  const withheld = unreadable || records.status === "loading";

  const submit = () => {
    if (!reference.trim() || withheld) return;
    void subscribe(target, reference.trim(), name.trim() || null).then(
      (outcome) => {
        // A refusal keeps the dialog open with the input intact — the
        // error shows right here, never on another page, and from what the
        // call answered rather than from a slot a concurrent read clears.
        if ("error" in outcome) {
          setError(outcome.error);
          return;
        }
        setError(null);
        setReference("");
        setName("");
        onOpenChange(false);
      },
    );
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Subscribe to a marketplace</DialogTitle>
          <DialogDescription>
            {SUBSCRIBE_MEANS} Any repository that holds skills works — paste a
            GitHub repo, a git URL, a skills.sh link, or pick a local folder.
          </DialogDescription>
        </DialogHeader>
        <form
          className="space-y-3"
          onSubmit={(e) => {
            e.preventDefault();
            submit();
          }}
        >
          <div className="space-y-1.5">
            <Label htmlFor="subscribe-reference">Repository or folder</Label>
            <Input
              id="subscribe-reference"
              placeholder="owner/repo, a URL, or a folder path"
              value={reference}
              onChange={(e) => setReference(e.target.value)}
              autoFocus
            />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="subscribe-name">Name (optional)</Label>
              <Input
                id="subscribe-name"
                placeholder="how it shows in lists"
                value={name}
                onChange={(e) => setName(e.target.value)}
              />
            </div>
            <div className="space-y-1.5">
              <Label>Subscribe for</Label>
              <Select
                value={where}
                onValueChange={(next) => setWhere(next ?? "global")}
              >
                <SelectTrigger className="w-full">
                  <SelectValue>
                    {(current: string) => {
                      const scope = scopes.find(
                        (s) => scopeLabel(s) === current,
                      );
                      return scope ? scopeName(scope) : current;
                    }}
                  </SelectValue>
                </SelectTrigger>
                <SelectContent>
                  {scopes.map((scope) => (
                    <SelectItem
                      key={scopeLabel(scope)}
                      value={scopeLabel(scope)}
                    >
                      {scopeName(scope)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>
          {unreadable ? <RecordsUnreadableWriteNote scope={target} /> : null}
          {error ? (
            <p className="text-sm text-critical" role="alert">
              {error}
            </p>
          ) : null}
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => onOpenChange(false)}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              disabled={busy || !reference.trim() || withheld}
            >
              {busy ? "Subscribing…" : "Subscribe"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
