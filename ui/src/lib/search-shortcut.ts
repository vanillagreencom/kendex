// Plain-shape target so this stays testable without a DOM: real
// EventTarget elements structurally satisfy it at the call site.
interface ShortcutTarget {
  tagName?: string;
  isContentEditable?: boolean;
}

// The "/" shortcut should never steal a "/" the user meant to type.
export function isSearchShortcutKey(
  key: string,
  target: ShortcutTarget | null,
): boolean {
  if (key !== "/") return false;
  if (!target) return true;
  if (target.isContentEditable) return false;
  const tag = target.tagName?.toUpperCase();
  return tag !== "INPUT" && tag !== "TEXTAREA" && tag !== "SELECT";
}
