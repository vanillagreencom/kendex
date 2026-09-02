import { useSyncExternalStore } from "react";

/** How often an "N ago" label re-reads the clock. One rate for every age on
 *  screen, so two of them never disagree about how old the same minute is. */
export const AGE_TICK_MS = 30_000;

// One clock for every age on screen, not one per label. A table draws an age
// per row, so a hook holding its own interval would be an interval per row,
// all of them firing on the same schedule to say the same thing. The timer
// below runs while at least one label is mounted and stops with the last of
// them, so a page showing no age costs nothing.
let now = Date.now();
let timer: ReturnType<typeof setInterval> | null = null;
const readers = new Set<() => void>();

function subscribe(onChange: () => void): () => void {
  readers.add(onChange);
  if (timer === null) {
    // Read the clock rather than resume from wherever the last label left
    // it, which is however long ago that label unmounted.
    now = Date.now();
    timer = setInterval(() => {
      now = Date.now();
      for (const reader of readers) reader();
    }, AGE_TICK_MS);
  }
  return () => {
    readers.delete(onChange);
    if (readers.size === 0 && timer !== null) {
      clearInterval(timer);
      timer = null;
    }
  };
}

/** Now, re-read on a timer. An age label goes stale on its own — nothing a
 *  page does re-renders it often enough to keep it honest, and a label that
 *  froze at mount is worse than none: it reads as a fact. */
export function useNowTick(): number {
  return useSyncExternalStore(
    subscribe,
    () => now,
    () => now,
  );
}
