import { useEffect, useState } from "react";
import type { ImportSelection } from "@/bindings";
import { DotSpinner } from "@/components/loading";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
  IMPORT_HELP,
  IMPORT_NOTHING,
  IMPORT_READING,
} from "@/lib/copy-marketplaces";
import { useMineStore } from "@/stores/mine";
import { MineImportRow, type RowChoice } from "./mine-import-row";

/** Copy packages from this machine into one authored marketplace. Every
 * candidate lists where its bytes live; marketplace-origin content asks
 * for licence evidence before it copies. */
export function MineImportDialog({
  target,
  open,
  onOpenChange,
}: {
  /** The authored folder receiving the copies. */
  target: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const candidates = useMineStore((s) => s.candidates);
  const outcome = useMineStore((s) => s.outcome);
  const loadInventory = useMineStore((s) => s.loadInventory);
  const applyImport = useMineStore((s) => s.applyImport);
  const clearAction = useMineStore((s) => s.clearAction);
  const busy = useMineStore((s) => s.busy);
  const error = useMineStore((s) => s.actionError);
  const [choices, setChoices] = useState<Record<string, RowChoice>>({});

  useEffect(() => {
    if (open) {
      setChoices({});
      void loadInventory();
    } else {
      clearAction();
    }
  }, [open, loadInventory, clearAction]);

  const key = (kind: string, name: string) => `${kind}\x00${name}`;
  const choiceFor = (kind: string, name: string, hash: string): RowChoice =>
    choices[key(kind, name)] ?? {
      checked: false,
      hash,
      destination: name,
      licenseConfirmed: false,
      licenseBasis: "",
    };

  const selections: ImportSelection[] = (candidates ?? []).flatMap(
    (candidate) => {
      const choice = choiceFor(
        candidate.kind,
        candidate.name,
        candidate.origins.find((origin) => origin.hash !== "")?.hash ?? "",
      );
      if (!choice.checked || choice.hash === "") return [];
      return [
        {
          kind: candidate.kind,
          name: candidate.name,
          destination: choice.destination.trim() || candidate.name,
          hash: choice.hash,
          licenseConfirmed: choice.licenseConfirmed,
          licenseBasis: choice.licenseBasis.trim() || null,
        },
      ];
    },
  );

  const submit = () => {
    void applyImport(target, selections).then((ok) => {
      // Success keeps the dialog open on the outcome so the person sees
      // what was written; a refusal shows inline with choices intact.
      if (ok) setChoices({});
    });
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>Import packages</DialogTitle>
          <DialogDescription>{IMPORT_HELP}</DialogDescription>
        </DialogHeader>
        {outcome ? (
          <div className="space-y-2 text-sm">
            {outcome.written.map((written) => (
              <p key={written}>Imported {written}</p>
            ))}
            {outcome.alreadyPresent.map((present) => (
              <p key={present} className="text-muted-foreground">
                Already there: {present}
              </p>
            ))}
            {outcome.written.length === 0 &&
            outcome.alreadyPresent.length === 0 ? (
              <p className="text-muted-foreground">Nothing was selected.</p>
            ) : null}
          </div>
        ) : candidates === null ? (
          <p className="flex items-center gap-2 text-sm text-muted-foreground">
            <DotSpinner /> {IMPORT_READING}
          </p>
        ) : candidates.length === 0 ? (
          <p className="text-sm text-muted-foreground">{IMPORT_NOTHING}</p>
        ) : (
          <ScrollArea className="max-h-96">
            <div className="space-y-2 pr-3">
              {candidates.map((candidate) => {
                const fallback =
                  candidate.origins.find((origin) => origin.hash !== "")
                    ?.hash ?? "";
                const choice = choiceFor(
                  candidate.kind,
                  candidate.name,
                  fallback,
                );
                return (
                  <MineImportRow
                    key={key(candidate.kind, candidate.name)}
                    candidate={candidate}
                    choice={choice}
                    onChange={(next) =>
                      setChoices((current) => ({
                        ...current,
                        [key(candidate.kind, candidate.name)]: next,
                      }))
                    }
                  />
                );
              })}
            </div>
          </ScrollArea>
        )}
        {error ? (
          <p className="text-sm text-critical" role="alert">
            {error}
          </p>
        ) : null}
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            {outcome ? "Done" : "Cancel"}
          </Button>
          {outcome ? null : (
            <Button onClick={submit} disabled={busy || selections.length === 0}>
              {busy
                ? "Importing…"
                : `Import ${selections.length || ""}`.trimEnd()}
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
