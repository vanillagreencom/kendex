import type { Scope } from "@/bindings";
import { usePackageSetup } from "@/components/package/use-package-setup";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import { SETUP_NEEDED_LINK, setupNeededSummary } from "@/lib/copy-setup";
import { placeName } from "@/lib/update-groups";

/** The Overview's one line about setup: which projects have this package
 *  installed without its repository changes in force, and the way to the
 *  row that fixes one.
 *
 *  Only where there is something to act on. A package that changes nothing
 *  about the repository, one that is set up everywhere, and one whose
 *  state nobody could read all draw nothing: a line that appears whatever
 *  the answer is a line nobody reads, and "could not check" is not
 *  something the Overview can offer an action for — the Projects tab says
 *  what was read and what to press.
 *
 *  It reads the same store the Projects tab does, so the two never
 *  disagree and no second run of the package's check pays for this line. */
export function SetupSummary({
  name,
  scopes,
  onShow,
}: {
  name: string;
  scopes: Scope[];
  /** Put this project's row on screen. The line names a project, so the
   *  link goes to that project's row rather than to the tab. */
  onShow: (scope: Scope) => void;
}) {
  const { entryFor, declares } = usePackageSetup(name, scopes);
  if (!declares) return null;
  const needing = scopes.filter((scope) => {
    const state = entryFor(scope)?.setup?.status.state;
    return state === "notActive" || state === "needsRepair";
  });
  if (needing.length === 0) return null;
  return (
    <StatusNote
      tone="warning"
      className="mb-6"
      title={setupNeededSummary(
        needing.map((scope) => placeName(scope, scopes)),
      )}
      action={
        <Button
          variant="link"
          size="sm"
          className="px-0"
          onClick={() => needing[0] && onShow(needing[0])}
        >
          {SETUP_NEEDED_LINK}
        </Button>
      }
    />
  );
}
