// What the read that follows a reconnect found at the folder the project
// now points at.
//
// The reconnect repairs nothing: it moves one registry entry, and whatever
// the move left behind — a hook registered under the old path, files a
// declaration lands on, a config file nothing can parse — is still there
// afterwards. So the app reads the place again through the reads it
// already runs, the audit and the scan both, and says what is left where
// the app already offers to fix it. Nothing here proposes a repair of its
// own, and nothing here counts what Problems would not show.
import type { ScanResult, ScanWarning, Scope } from "@/bindings";
import { type BlockedPlace, blockedCount } from "@/lib/audit-counts";
import { placeIsReachable } from "@/lib/reachable-projects";
import type { Problem } from "@/stores/problems";

export type AfterReconnect =
  /** The read landed and found nothing here to fix. */
  | { state: "clean" }
  /** The read landed and this place has work waiting on Problems. */
  | { state: "problems"; count: number }
  /** The read could not answer for this place, which is not the same as
   *  finding nothing: a clean line over an unconfirmed reading is the one
   *  claim this must never make. */
  | { state: "unchecked" };

const at = (root: string, scope: Scope | null): boolean =>
  scope?.scope === "project" && scope.root === root;

/** Whether this file sits under that folder.
 *
 *  Both are absolute paths a scan produced, so the folder is a prefix of
 *  what is inside it — spelled with whichever separator the machine that
 *  wrote them uses, since each is a `PathBuf` serialized as it stands. A
 *  test for one separator alone matches nothing on the other platform and
 *  would report every Windows project clean.
 *
 *  Asked here rather than answered in core: a warning names a file, and
 *  one file can belong to several places — `~/.claude.json` is the MCP
 *  surface of the personal scope and of every project — so the scan says
 *  it once, under the first surface that read it, and a single scope
 *  stamped on it would be a half-truth. */
const under = (root: string, path: string): boolean =>
  path === root || path.startsWith(`${root}/`) || path.startsWith(`${root}\\`);

export function afterReconnect(
  problems: Problem[],
  blocked: BlockedPlace[] | null,
  warnings: ScanWarning[],
  result: ScanResult | null,
  root: string,
): AfterReconnect {
  // Every reading that did not land, and they are all the same answer: no
  // reading, so no claim. The scan landing is not the same as this folder
  // being read: a scan that could not open the destination puts it in the
  // missing list and leaves it out of what it read, and an audit with no
  // manifest for a folder reads as an empty scope — every count below
  // then comes to zero and the line says the folder needs no repair. So
  // the same judge the destinations use is asked here, where the outcome
  // is reported. The audit's own failure is `blocked` being null; a place
  // inside a landed audit can still be one kendex could not read; and a
  // scan that could not finish is a problem about the machine rather than
  // about any one place, which is what its null scope means — the read
  // that would have covered this folder is exactly the one that failed.
  if (!placeIsReachable(root, result)) return { state: "unchecked" };
  if (blocked === null) return { state: "unchecked" };
  if (
    problems.some(
      (problem) => problem.scope === null || at(root, problem.scope),
    )
  )
    return { state: "unchecked" };
  // The items, not the places holding them: one place carries every
  // blocked row at that folder, and its length is 1 however many there
  // are. The count is a sentence a person reads.
  // Both kinds Problems draws for a place: a declaration landing on files
  // kendex did not write, and a file it could not read as the document its
  // surface expects. A line saying nothing else needs doing while Problems
  // holds a repair for this very folder is the claim this must not make,
  // and the second kind is in no audit row.
  const count =
    blockedCount(blocked.filter((place) => at(root, place.scope))) +
    warnings.filter((warning) => under(root, warning.path)).length;
  return count > 0 ? { state: "problems", count } : { state: "clean" };
}
