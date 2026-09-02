// Vitest reports an unhandled rejection while the file that started it is
// still running, and the run exits 1. A promise that rejects after the file
// has ended is dropped instead: under the default `isolate` a worker runs
// exactly one file, and the process holding the pending timer is torn down
// with it, so the rejection never happens. That is how
// update-follow.dom.test.tsx passed while answering `packageSetRev` with an
// `AuditView` where the command returns a `PackageUpdate` — a green run over
// a file that leaks rejections is the same failure as a control that will
// not go red.
//
// So this setup file adds nothing to the report and, more to the point,
// takes nothing off it: registering a second `unhandledRejection` listener
// would make vitest's own handler bail, and with it every rejection vitest
// already catches — including one leaked at module scope in a file whose
// cases are all skipped, where no hook of ours would ever run. All this does
// is hold the file open past its last case, so work the file left running
// gets its chance to reject while the worker is still alive.
//
// vitest 4.1.10 also ships `--detectAsyncLeaks`, which names the dangling
// promise and its line without waiting for it to settle. It is off by
// default and does not fail the run, so it stays a debugging aid: this is
// what makes the run red.
import { afterAll } from "vitest";

/** How long the file stays open after its last case — long enough for the
 *  shape this catches, a mocked command's promise rejecting a turn or two
 *  behind the case that called it, without holding every file open for work
 *  that is not coming. A rejection scheduled beyond it still escapes. */
const CLOSING_WINDOW_MS = 50;

// Captured before any test can call `vi.useFakeTimers()`, which replaces the
// global: a wait on a fake clock nobody advances never returns.
const realSetTimeout = globalThis.setTimeout.bind(globalThis);
const wait = (ms: number) =>
  new Promise<void>((resolve) => realSetTimeout(resolve, ms));

afterAll(async () => {
  await wait(CLOSING_WINDOW_MS);
  // Node flags a rejection at the end of the turn it settles in, not in it.
  await wait(0);
});
