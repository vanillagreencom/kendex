/** Hand back the value already on screen when a fresh read says exactly
 *  what the last one did. Identity is what React's memoization compares, so
 *  a re-read that changed nothing must not look like a change: every screen
 *  joining on it would re-render for news that is not news. Both sides come
 *  from the same serializer, so their key order is the same.
 */
export function keepIfSame<T>(previous: T, next: T): T {
  return JSON.stringify(previous) === JSON.stringify(next) ? previous : next;
}
