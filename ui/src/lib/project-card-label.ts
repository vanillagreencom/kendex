/**
 * A project card shows the folder's last segment as its name, so two
 * registered folders can put the same word on two cards — /work/client and
 * /personal/client are both "client". What separates them on screen is the
 * full path printed under the name, which a button's own label leaves out.
 * This is that label with the path in it, so each card's button announces
 * the place it opens instead of a word another card also answers to.
 *
 * Personal is one card with no folder, and its name already stands alone.
 */
export function showEverythingLabel(name: string, path?: string): string {
  return path
    ? `Show everything in ${name}, ${path}`
    : `Show everything in ${name}`;
}
