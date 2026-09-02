// A shaped refusal — `WriteRefused`, `AccountCallRefused` — says why a write
// stopped through a `kind` its reader branches on. A transport failure has no
// kind: `typedError` in the generated bindings folds it into the message
// alone, because there is no shape it could invent that fits every command's
// refusal type. The bindings declare that widening as `E | string`, so a
// reader that goes off the fields rather than through here is a type error
// rather than a silence found later.
//
// Read by `kind`, the folded message misses every arm and lands in whatever
// the reader does last: the editor tests `stale` first, so a broken pipe
// falls past it and shows a blank error (`ui/src/stores/editor.ts`), and the
// settings notice tests `failed` first, so the same pipe is reported as the
// settings file having moved (`ui/src/stores/notice.ts`). These two are how a
// reader asks its questions so both land.

/** A refusal the commands answer with through a `kind`: `WriteRefused` and
 *  `AccountCallRefused`. `ForkBesideError` discriminates on `phase` instead
 *  and is outside these two — `ui/src/stores/updates-edits.ts` reads it. */
type Shaped = { kind: string; message?: string };

/** The refusal's own kind, or null where the transport failed and left a
 *  message with no shape around it — a kindless shape answers null too. */
export function refusalKind(refusal: Shaped | string): string | null {
  return typeof refusal === "string" ? null : (refusal.kind ?? null);
}

/** What stopped the write, in the words the person gets — null only where the
 *  refusal is a kind that carries none, such as a file that moved. */
export function refusalWords(refusal: Shaped | string): string | null {
  return typeof refusal === "string" ? refusal : (refusal.message ?? null);
}

/** Whether the refusal is the engine's own shape rather than a folded
 *  transport failure. For a reader that needs the shape itself, not its
 *  words: a transport failure is news about the channel, never about what
 *  the command was refusing. */
export function isShapedRefusal<T extends Shaped>(
  refusal: T | string,
): refusal is T {
  return typeof refusal !== "string";
}
