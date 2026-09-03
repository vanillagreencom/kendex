import type { ItemKind, Scope } from "@/bindings";
import { DestinationSelect } from "@/components/marketplaces/destination-select";
import {
  type Choice,
  HarnessSelect,
  isInstallable,
} from "@/components/marketplaces/harness-select";
import { Button } from "@/components/ui/button";

/** Where a set's ticked members install, on what, and the button that
 * installs them. The set page owns every answer here — which place, which
 * tools, which members — and what one answer does to the others; this draws
 * the row.
 *
 * `choice` is not only this row's: the page's own Install all, in the
 * header, installs the whole set with whatever this picker last answered.
 * So the tool picker here decides how the button at the top installs, and
 * moving either one has to account for the other.
 *
 * The row is drawn above the set's own read and stays on screen while that
 * read is loading or failed, because the place it picks is what a failed
 * read is escaped by. Nothing here acts on a set the page does not hold:
 * `picked` is 0 in every state that reaches one, since choosing a place
 * clears the ticks and a landed install clears them again. */
export function BundleInstallBar({
  browsing,
  target,
  kinds,
  choice,
  picked,
  busy,
  onPlace,
  onChoice,
  onInstall,
}: {
  browsing: Scope;
  /** Where the install lands: the place picked, or the browsed one. */
  target: Scope;
  /** The kinds actually ticked, which is what the tool picker may offer. */
  kinds: ItemKind[];
  choice: Choice;
  picked: number;
  busy: boolean;
  onPlace: (scope: Scope) => void;
  onChoice: (choice: Choice) => void;
  onInstall: () => void;
}) {
  return (
    <div className="mb-3 flex items-center justify-end gap-2">
      <DestinationSelect
        browsing={browsing}
        value={target}
        onChange={onPlace}
      />
      <HarnessSelect
        scope={target}
        kinds={kinds}
        value={choice}
        onChange={onChoice}
      />
      <Button
        variant="outline"
        disabled={busy || picked === 0 || !isInstallable(choice)}
        onClick={onInstall}
      >
        Install {picked} selected
      </Button>
    </div>
  );
}
