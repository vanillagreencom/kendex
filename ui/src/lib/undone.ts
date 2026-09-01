// What a removal did about the repository the packages leaving with it had
// armed. The lines are Rust's, the same ones the terminal prints, so the
// window and the terminal say one thing about one repository — this side
// only puts them on the screen.
import { toast } from "sonner";

/** How many lines are shown before the rest are counted instead. An
 *  uninstaller is a third party and its output is uncapped, and sonner
 *  shows three toasts at a time for four seconds each — so a chatty one
 *  becomes a minutes-long drain that buries whatever the person does
 *  next. The first lines are the ones that name the package and what ran;
 *  the tail is the script talking. */
const SHOWN = 10;

/** Show a removal's account, one line at a time. Silent when the removal
 *  took no declaring package away, which is almost every removal. */
export function sayUndone(undone: string[] | undefined) {
  const lines = undone ?? [];
  for (const line of lines.slice(0, SHOWN)) toast.message(line);
  const rest = lines.length - SHOWN;
  if (rest > 0) toast.message(`and ${rest} more line${rest === 1 ? "" : "s"}`);
}

/** The account an answer carries, wherever the command puts it: on the
 *  answer itself, or on the standing that answer nests. Read here rather
 *  than at each call site, so a command added later is announced by the
 *  write it goes through instead of by somebody remembering. */
function accountIn(data: unknown): string[] {
  if (typeof data !== "object" || data === null) return [];
  const held = data as { undone?: unknown; view?: { undone?: unknown } | null };
  const found = held.undone ?? held.view?.undone;
  if (!Array.isArray(found)) return [];
  return found.filter((line): line is string => typeof line === "string");
}

/** Say what a write's answer accounts for, and hand the answer straight
 *  back. Takes the whole result, so a refusal says nothing and a landed
 *  write is read wherever it keeps its account.
 *
 *  This is the announcement riding on the write. The alternative — a call
 *  beside each command — is a rule every new mutation has to remember, and
 *  the module this serves records that rule being forgotten for a whole
 *  round with one of five paths wired. */
export function saying<T>(answer: T): T {
  const it = answer as { status?: unknown; data?: unknown };
  if (typeof it === "object" && it !== null && it.status === "ok") {
    sayUndone(accountIn(it.data));
  }
  return answer;
}
