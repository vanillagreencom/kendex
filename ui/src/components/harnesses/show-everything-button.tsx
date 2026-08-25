import { clickEndedSelection } from "@/lib/click-asks-to-open";
import { showEverythingLabel } from "@/lib/show-everything-label";

/**
 * The name-as-button that asks for everything one place has — a project
 * card's name, a harness row's name. The count badges beside it each
 * narrow to one kind, and none of them can answer "all of it". One
 * component rather than one markup convention, so the two surfaces
 * cannot drift in wording, styling, or behavior.
 */
export function ShowEverythingButton({
  name,
  path,
  onOpen,
}: {
  name: string;
  /** The folder the name abbreviates, where it has one — it joins the
   * accessible label so two cards sharing a last segment announce
   * different places. */
  path?: string;
  onOpen: () => void;
}) {
  return (
    <button
      type="button"
      // Fires before any surface guard around it, so it declines a
      // selection-ending drag itself.
      onClick={(event) => {
        if (!clickEndedSelection(event)) onOpen();
      }}
      aria-label={showEverythingLabel(name, path)}
      className="truncate text-sm font-medium hover:underline"
    >
      {name}
    </button>
  );
}
