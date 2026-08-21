/** Answers from the newest request only. A page whose address changes
 * while a read is in flight — a repository page carrying on as the
 * subscription it just gained — must not let the older answer land on top
 * of the newer one. */
export function latestOnly() {
  let generation = 0;
  return <T>(pending: Promise<T>): Promise<T | undefined> => {
    const mine = ++generation;
    return pending.then((value) => (mine === generation ? value : undefined));
  };
}
