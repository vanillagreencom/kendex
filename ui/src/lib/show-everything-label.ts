/**
 * What a show-everything control announces — the name button on a project
 * card or a harness row, opening the Library scoped to just that place or
 * harness. One phrase shared by both surfaces, so the same affordance never
 * says two different things.
 *
 * A project card shows the folder's last segment as its name, so two
 * registered folders can put the same word on two cards — /work/client and
 * /personal/client are both "client". What separates them on screen is the
 * full path printed under the name, which a button's own label leaves out;
 * the path in the label puts it back, so each card's button announces the
 * place it opens instead of a word another card also answers to.
 *
 * Personal is one card with no folder, and a harness is one of a fixed
 * seven: those names already stand alone.
 */
export function showEverythingLabel(name: string, path?: string): string {
  return path
    ? `Show everything in ${name}, ${path}`
    : `Show everything in ${name}`;
}
