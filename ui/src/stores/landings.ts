/** Orders the landings of overlapping reads so a slow early one cannot
 *  overwrite a fresher answer. Reads rank by when they BEGIN — of two
 *  answers, the later-begun read saw the newer state — while a
 *  side-effecting operation's answer ranks by when it LANDS: it reports
 *  the state its own work produced, newer than any read still in flight
 *  however early that read began. */
export function landings() {
  let begun = 0;
  let written = 0;
  return {
    /** Take a ticket as a read begins. */
    begin: (): number => ++begun,
    /** Whether the landing holding this ticket may write — true marks it
     *  written, false means a fresher landing already did. */
    land: (ticket: number): boolean => {
      if (ticket <= written) return false;
      written = ticket;
      return true;
    },
    /** Land a side-effecting operation's answer: it always writes, and
     *  outranks every read begun before this moment. */
    landAuthoritative: (): void => {
      written = ++begun;
    },
  };
}
