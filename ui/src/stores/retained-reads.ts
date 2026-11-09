import { invalidations } from "@/lib/read-state";

/** When a read kept past the page that asked for it stops being the answer:
 *  a place's manifest and settings (`editor-cache.ts`) and a package's own
 *  reads (`package-reads.ts`). Each kept answer is stamped with [since] as
 *  its read began, and is reused only while nothing has moved this since.
 *
 *  Whatever may change what those reads answer — a write, a fetch that
 *  moves a mirror, a request to read the machine again — moves this when
 *  it ends, whether or not it reported success: a failure says nothing
 *  about whether the files moved. `grep -rn "retainedReads.moved" ui/src`
 *  is the list. A read begun before or during one is never current after
 *  it, so a write's own read-back stays a view of the moment and the next
 *  demand asks again. No clock: an answer is as good after an hour of
 *  nothing happening as after a second. */
export const retainedReads = invalidations();
