/** Names in a line, the way a person writes them: no serial comma, and the
 *  `and` only in front of the last one. Three names joined with two `and`s
 *  read as a chant rather than a list.
 *
 *  Alone in its own module on purpose. This is one wording rule that four
 *  surfaces share — the places a package is customized in
 *  (`place-marks.ts`), the places it is installed in
 *  (`installed-places.ts`), the kinds a catalog holds
 *  (`copy-marketplaces.ts`), and the harnesses a hook runs in
 *  (`copy-customize.ts`) — where `copy.ts` holds a page's own prose. Do not
 *  fold it back in: a shared rule living beside page copy is how it grew a
 *  second copy the first time.
 *
 *  A list with nothing in it is the caller's to handle — what an empty list
 *  should say differs by surface, and this one has no opinion about it.
 *
 *  One surface joins differently and keeps its own: `copy-projects.ts`'s
 *  `eitherOf`, which lists the marketplaces a package can be reinstalled
 *  from. It offers a choice rather than making a claim about all of them,
 *  and it takes the serial comma — "alpha, beta, or gamma" — so it differs
 *  in punctuation as well as conjunction. */
export const listed = (names: string[]): string =>
  names.length < 3
    ? names.join(" and ")
    : `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;
