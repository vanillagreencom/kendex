// The lines a write's answer accounts for, and why that account is short.
// They are Rust's; this side only puts them on the screen.
import { toast } from "sonner";
import { UNFINISHED_STEP, unfinishedTitle } from "@/lib/copy";
import { NO_REASON_GIVEN } from "@/lib/settled";
import { useProblemsStore } from "@/stores/problems";

/** Say the step behind a landed write that failed — `AuditView.unfinished`,
 *  on the answer or on the view it nests — beside what the surface already
 *  said for the write. Absent, it says nothing.
 *
 *  Not a refusal: the write stands, so the caller's own success line, its
 *  account and its fresh view all still land. The failure goes to the error
 *  dialog rather than a toast because it is a failure of an action the
 *  person just took, and because the commit offer waits behind that dialog
 *  (`asks-first.ts`): the person reads what landed and what did not before
 *  being asked what to do with the files, and leaving or refusing the
 *  commit afterwards takes neither back. A run over several writes keeps
 *  each one's account through the dialog's own join rule
 *  (`useProblemsStore`). */
export function sayUnfinished(
  subject: string,
  unfinished: string | null | undefined,
): void {
  if (unfinished === null || unfinished === undefined) return;
  useProblemsStore.getState().showError({
    title: unfinishedTitle(subject),
    message: unfinished === "" ? NO_REASON_GIVEN : unfinished,
    steps: [UNFINISHED_STEP],
  });
}

/** Show the account, every line of it, uncut. Nothing below the window
 *  can tell kendex's own notices from a departing package's output by the
 *  time the account reaches here, so a cut by position would eat whichever
 *  line happens to fall past it — a package's "declares no uninstaller"
 *  notice, the only place kendex says an effect was left standing and
 *  names the manual remedy. */
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
