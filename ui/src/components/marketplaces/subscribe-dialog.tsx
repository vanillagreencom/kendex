import { useState } from "react";
import type { Scope } from "@/bindings";
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
import { scopeLabel } from "@/lib/derive";
import { scopeName } from "@/lib/labels";
import { everyPlace } from "@/lib/scope";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useSettingsStore } from "@/stores/settings";

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
  const error = useMarketplacesStore((s) => s.error);
  const projects = useSettingsStore((s) => s.settings?.projects ?? []);
  const [reference, setReference] = useState(initialReference);
  const [name, setName] = useState("");
  const [where, setWhere] = useState("global");

  const scopes = everyPlace(projects);

  const submit = () => {
    if (!reference.trim()) return;
    const target =
      scopes.find((s) => scopeLabel(s) === where) ??
      ({ scope: "global" } as Scope);
    void subscribe(target, reference.trim(), name.trim() || null).then((ok) => {
      // A refusal keeps the dialog open with the input intact — the
      // error shows right here, never on another page.
      if (!ok) return;
      setReference("");
      setName("");
      onOpenChange(false);
    });
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Subscribe to a marketplace</DialogTitle>
          <DialogDescription>
            Any repository that holds skills works — paste a GitHub repo, a git
            URL, a skills.sh link, or pick a local folder.
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
            <Button type="submit" disabled={busy || !reference.trim()}>
              {busy ? "Subscribing…" : "Subscribe"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
