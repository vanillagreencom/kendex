// How long a test file is held open after its last case, resolved from the
// environment. It lives apart from `unhandled-rejections.ts` so it can be
// asserted directly: the value that runs on every real test file is the
// default, and no run that needs a window uses the default, so reaching it
// through a nested run would take a fixture rejecting inside 50ms — the
// racy shape the fixtures were widened away from.

/** The window every test file gets unless a run asks for another. */
export const DEFAULT_CLOSING_WINDOW_MS = 50;

// Above this `setTimeout` overflows and fires after 1ms instead, which is a
// window of none.
const MAX_TIMEOUT_MS = 2 ** 31 - 1;

/** The window `raw` asks for, or the default when it asks for nothing usable.
 *  Anything `setTimeout` would silently turn into ~1ms — a sign typo, an
 *  overflow, a non-number — falls back rather than reaching it. */
export function resolveClosingWindowMs(raw: string | undefined): number {
  const asked = Number(raw);
  if (raw === undefined || raw === "") return DEFAULT_CLOSING_WINDOW_MS;
  if (!Number.isFinite(asked)) return DEFAULT_CLOSING_WINDOW_MS;
  if (asked <= 0 || asked > MAX_TIMEOUT_MS) return DEFAULT_CLOSING_WINDOW_MS;
  return asked;
}
