/** Which read of the update standing may speak, when several overlap.
 *
 *  Held here rather than in the store so the ordering can be read — and
 *  tested — as one thing, apart from what it happens to guard. */
export function updateTickets() {
  // Every read of the standing takes a ticket. A read issued before a fork
  // or a discard lands, resolving after it, would otherwise put its
  // pre-resolution rows back — and the marks, the notice and the Review
  // count all read those rows, so a state someone just resolved reappears.
  //
  // Two kinds of read, and one counter cannot rank them. A poll reads what
  // the mirrors already say; Check for updates fetches first, so its answer
  // is the newer one however the two land. Sharing a ticket, a poll issued
  // during a check takes the newer number and commits the pre-fetch rows,
  // and the check the person asked for is thrown away with the screen still
  // showing what it was asked to replace.
  let reads = 0;
  let checks = 0;
  let checking = 0;
  // A read that follows a write this app just made. It is not a poll —
  // nobody is guessing, the file moved and this is the reading of it — so
  // it must land, and a check that was already in flight must not put the
  // pre-write rows back over it afterwards. Counting it as a check does
  // both: it lands on the fetched predicate, and every older check finds
  // its own count superseded and declines.
  const ticket = (fetched = false, afterWrite = false) => {
    reads += 1;
    const mine = reads;
    if (fetched) {
      checks += 1;
      checking += 1;
    } else if (afterWrite) {
      checks += 1;
    }
    const mineCheck = checks;
    // Whether a fetch was already running when this read began. A poll that
    // started mid-fetch is reading the pre-fetch mirrors however long it
    // takes to return, so asking what is in flight when it *lands* accepts
    // exactly that poll once the fetch has finished — and puts the rows the
    // person asked to replace back over the fetched ones.
    const during = checking > 0;
    return fetched || afterWrite
      ? // Only a later fetch answers for one: a poll that started after it
        // is reading the older truth, whenever it happens to land.
        () => mineCheck === checks
      : // And a poll lands only while it is the newest read, with no fetch
        // running when it started and none started since.
        () => mine === reads && !during && mineCheck === checks;
  };

  /** One fetch has finished. Answers whether any is still running, since
   *  the spinner belongs to every fetch rather than to whichever lands
   *  first — two overlapping and the first to return would take it down
   *  with the other still going. */
  const fetchEnded = () => {
    checking -= 1;
    return checking > 0;
  };

  return { ticket, fetchEnded };
}
