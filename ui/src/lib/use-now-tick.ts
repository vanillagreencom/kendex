import { useEffect, useState } from "react";

/** How often an "N ago" label re-reads the clock. One rate for every age on
 *  screen, so two of them never disagree about how old the same minute is. */
export const AGE_TICK_MS = 30_000;

/** Now, re-read on a timer. An age label goes stale on its own — nothing a
 *  page does re-renders it often enough to keep it honest, and a label that
 *  froze at mount is worse than none: it reads as a fact. */
export function useNowTick(): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), AGE_TICK_MS);
    return () => clearInterval(id);
  }, []);
  return now;
}
