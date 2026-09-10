// What the read that follows a reconnect found at the folder the project
// now points at.
//
// The reconnect repairs nothing: it moves one registry entry, and whatever
// the move left behind — a hook registered under the old path, files a
// declaration lands on — is still there afterwards. So the app reads the
// place again through the audit it already runs and says what is left,
// where the app already offers to fix it. Nothing here proposes a repair
// of its own.
import type { Scope } from "@/bindings";
import type { BlockedPlace } from "@/lib/audit-counts";
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

export function afterReconnect(
  problems: Problem[],
  blocked: BlockedPlace[] | null,
  root: string,
): AfterReconnect {
  // Null is the audit's own failure, and a place inside a landed audit can
  // still be one kendex could not read. Both are the same answer here: no
  // reading, so no claim.
  if (blocked === null) return { state: "unchecked" };
  if (problems.some((problem) => at(root, problem.scope)))
    return { state: "unchecked" };
  const count = blocked.filter((place) => at(root, place.scope)).length;
  return count > 0 ? { state: "problems", count } : { state: "clean" };
}
