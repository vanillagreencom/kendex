// A shaped refusal — `WriteRefused`, `AccountCallRefused` — says why a write
// stopped through a `kind` its reader branches on. A transport failure has no
// kind: `typedError` in the generated bindings folds it into the message
// alone, because there is no shape it could invent that fits every command's
// refusal type. Read by `kind`, that message answers as whichever arm the
// reader tests for last — a reload offered for a broken pipe, or nothing shown
// at all. These two are how a reader asks its questions so both land.

/** Any refusal shape the commands answer with: a kind, and the words that go
 *  with it where that kind has any. */
type Shaped = { kind: string; message?: string };

/** The refusal's own kind, or null where the transport failed and left a
 *  message with no shape around it. */
export function refusalKind(refusal: Shaped): string | null {
  return typeof (refusal as unknown) === "string" ? null : refusal.kind;
}

/** What stopped the write, in the words the person gets — null only where the
 *  refusal is a kind that carries none, such as a file that moved. */
export function refusalWords(refusal: Shaped): string | null {
  if (typeof (refusal as unknown) === "string") {
    return refusal as unknown as string;
  }
  return refusal.message ?? null;
}
