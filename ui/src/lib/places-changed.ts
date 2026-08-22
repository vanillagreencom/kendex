/** Whether the set of places has changed since this was last asked, and
 *  remembering the answer.
 *
 *  Adding or removing a project changes which places exist, and both reads
 *  behind a package's per-place marks are per place. Without noticing, they
 *  next run on a window focus, so a project added mid-session shows its
 *  packages as unchecked until the window has been away and come back — a
 *  place nobody looked at, when looking is one read away.
 *
 *  It lives here rather than inside the effect that uses it because an
 *  effect does not run under this suite's static rendering: the decision is
 *  the part worth pinning, and it cannot be pinned where it cannot run. The
 *  first ask is always false — whatever ran at mount has already read them. */
export function placesChanged(
  known: { current: string | null },
  projects: string[] | undefined,
): boolean {
  // Serialised, not joined: a project path can hold whatever separator a
  // join picks, and then ["/a", "/b"] and ["/a /b"] are the same string —
  // two different sets of places that would read as unchanged.
  const now = JSON.stringify(projects ?? []);
  const first = known.current === null;
  const changed = !first && known.current !== now;
  known.current = now;
  return changed;
}
