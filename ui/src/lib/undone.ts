// What a removal did about the repository the packages leaving with it had
// armed. The lines are Rust's, the same ones the terminal prints, so the
// window and the terminal say one thing about one repository — this side
// only puts them on the screen.
import { toast } from "sonner";

/** Show a removal's account, every line of it. Silent when the removal
 *  took no declaring package away, which is almost every removal.
 *
 *  Every line, uncut. Nothing below the window can tell kendex's own
 *  stand-down notices from a departing package's output by the time the
 *  account reaches here, so a cut by position would eat whichever line
 *  happens to fall past it — and the first one it ate was a later
 *  package's "declares no uninstaller" notice, the only place kendex says
 *  an effect was left standing and names the manual remedy. */
export function sayUndone(undone: string[] | undefined) {
  for (const line of undone ?? []) toast.message(line);
}

/** The lines of `value`, or nothing if it is not a list of them. */
function lines(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.filter((line): line is string => typeof line === "string");
}

/** The account an answer carries, wherever the command puts it: as the
 *  answer itself, on the answer, or on the standing the answer nests. The
 *  three shapes are read here rather than at each call site, so a caller
 *  hands [`saying`] whatever its command answered and needs to know
 *  nothing about where the account sits in it.
 *
 *  First NON-EMPTY, not first non-nullish. `??` prefers an outer empty
 *  list over a populated nested one, which would silence exactly the
 *  answers that carry both. A shape with no account anywhere returns
 *  nothing, and that branch is written out so the silence is a decision
 *  rather than a fall-through. */
function accountIn(data: unknown): string[] {
  const bare = lines(data);
  if (bare.length > 0) return bare;
  if (typeof data !== "object" || data === null) return [];
  const held = data as { undone?: unknown; view?: { undone?: unknown } | null };
  const own = lines(held.undone);
  if (own.length > 0) return own;
  const nested = lines(held.view?.undone);
  if (nested.length > 0) return nested;
  return [];
}

/** Say what a write's answer accounts for, and hand the answer straight
 *  back. Takes the whole result, so a refusal says nothing and a landed
 *  write is read wherever it keeps its account.
 *
 *  Applied at the call site, around the command's own answer. It is one of
 *  two spellings: a write that can take a declaring package away either
 *  wraps its answer in this, or hands [`sayUndone`] the account it already
 *  holds off a shape it has read itself. Both together are the set —
 *  `grep -rnE "saying\(|sayUndone\(" ui/src` finds them. */
export function saying<T>(answer: T): T {
  const it = answer as { status?: unknown; data?: unknown };
  if (typeof it === "object" && it !== null && it.status === "ok") {
    sayUndone(accountIn(it.data));
  }
  return answer;
}
