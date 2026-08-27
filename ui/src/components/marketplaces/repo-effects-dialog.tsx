import type { Disclosure } from "@/bindings";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  COMPANION_INSTALLED,
  COMPANION_NOT_INSTALLED,
  REPO_EFFECTS_APPLY_LABEL,
  REPO_EFFECTS_COMPANIONS_LABEL,
  REPO_EFFECTS_DECLINE_LABEL,
  REPO_EFFECTS_DONE_LABEL,
  REPO_EFFECTS_NO_UNDO,
  REPO_EFFECTS_NOTHING_TO_RUN,
  REPO_EFFECTS_SHARED_MARK,
  REPO_EFFECTS_SHARED_NOTE,
  REPO_EFFECTS_STANDING,
  REPO_EFFECTS_UNDO_LABEL,
  REPO_EFFECTS_WRITES_LABEL,
  repoEffectsTitle,
} from "@/lib/copy-repo-effects";
import { abbreviateHome } from "@/lib/drift-merge";
import { useMarketplacesStore } from "@/stores/marketplaces";

/** The second question an install can ask, rendered once in App.tsx: what
 *  a package does to the repository beyond the files kendex manages, and
 *  whether to let it. One package at a time, each with its own yes, in the
 *  order the install reported them. The package's files are already in;
 *  closing this leaves them in and the repository as it was.
 *
 *  Every word of the package's on screen is core's display text, already
 *  escaped once there: a direction-flipping character in a declared path
 *  would otherwise read as a different file from the one being
 *  authorized. Nothing here displays the raw declaration; it is read only
 *  for whether an installer exists, and handed back untouched. */
export function RepoEffectsDialog() {
  const pending = useMarketplacesStore((s) => s.pendingEffects);
  const busy = useMarketplacesStore((s) => s.busy);
  const apply = useMarketplacesStore((s) => s.applyRepoEffect);
  const decline = useMarketplacesStore((s) => s.declineRepoEffect);
  if (!pending) return null;
  const disclosure = pending.queue[0];
  const runnable = disclosure.declared.installer !== null;
  return (
    <Dialog
      open
      onOpenChange={(next) => {
        // Dismissing is declining: nothing runs without the button.
        if (!next && !busy) decline();
      }}
    >
      <DialogContent className="max-h-[85vh] overflow-y-auto sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>{repoEffectsTitle(disclosure.name)}</DialogTitle>
          <DialogDescription>{REPO_EFFECTS_STANDING}</DialogDescription>
        </DialogHeader>
        <DisclosureBody disclosure={disclosure} />
        <DialogFooter>
          {runnable ? (
            <>
              <Button variant="outline" disabled={busy} onClick={decline}>
                {REPO_EFFECTS_DECLINE_LABEL}
              </Button>
              <Button disabled={busy} onClick={() => void apply()}>
                {REPO_EFFECTS_APPLY_LABEL}
              </Button>
            </>
          ) : (
            <Button disabled={busy} onClick={decline}>
              {REPO_EFFECTS_DONE_LABEL}
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** The block, in the order a reader needs it: what changes, what is
 *  written, which packages take part, whatever the package itself wants
 *  read, and how to undo it. Every line is the package's own words or a
 *  fact kendex knows about this machine; nothing here explains what a
 *  declaration means, because that is the package's contract. */
function DisclosureBody({ disclosure }: { disclosure: Disclosure }) {
  const shared = disclosure.writes.some((written) => written.shared);
  return (
    <div className="space-y-4 text-sm">
      <p className="font-medium">{disclosure.summary}</p>
      {disclosure.writes.length > 0 ? (
        <section className="space-y-1.5">
          <h3 className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
            {REPO_EFFECTS_WRITES_LABEL}
          </h3>
          <ul className="space-y-0.5">
            {disclosure.writes.map((written) => (
              <li key={written.path} className="flex items-baseline gap-2">
                <span className="break-all font-mono text-xs">
                  {abbreviateHome(written.path)}
                </span>
                {written.shared ? (
                  <span className="text-xs text-muted-foreground">
                    {REPO_EFFECTS_SHARED_MARK}
                  </span>
                ) : null}
              </li>
            ))}
          </ul>
          {shared ? (
            <p className="text-muted-foreground">{REPO_EFFECTS_SHARED_NOTE}</p>
          ) : null}
        </section>
      ) : null}
      {disclosure.companions.length > 0 ? (
        <section className="space-y-1.5">
          <h3 className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
            {REPO_EFFECTS_COMPANIONS_LABEL}
          </h3>
          <ul className="space-y-0.5">
            {disclosure.companions.map((companion) => (
              <li key={companion.name} className="flex items-baseline gap-2">
                <span className="font-mono text-xs">{companion.name}</span>
                <span className="text-xs text-muted-foreground">
                  {companion.installed
                    ? COMPANION_INSTALLED
                    : COMPANION_NOT_INSTALLED}
                </span>
              </li>
            ))}
          </ul>
        </section>
      ) : null}
      {disclosure.notes.map((note) => (
        <p key={note} className="text-muted-foreground">
          {note}
        </p>
      ))}
      <section className="space-y-1">
        <h3 className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
          {REPO_EFFECTS_UNDO_LABEL}
        </h3>
        {/* Never "remove the package": removing it takes the scripts away
            and leaves the effect. What is true is what the package said. */}
        <p className="text-muted-foreground">
          {disclosure.undo ?? REPO_EFFECTS_NO_UNDO}
        </p>
      </section>
      {disclosure.declared.installer === null ? (
        <p className="text-muted-foreground">{REPO_EFFECTS_NOTHING_TO_RUN}</p>
      ) : null}
    </div>
  );
}
