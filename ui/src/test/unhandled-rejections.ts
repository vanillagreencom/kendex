// Vitest reports an unhandled rejection while the file that started it is
// still running, and the run exits 1. A promise that rejects after the file
// has ended is dropped instead: under the default `isolate` a worker runs
// exactly one file, and the process holding the pending timer is torn down
// with it. A mocked command answering with the wrong payload type rejects a
// turn or two behind the case that called it, which lands on the wrong side
// of that line.
//
// So this setup file adds nothing to the report and, more to the point,
// takes nothing off it: registering a second `unhandledRejection` listener
// would make vitest's own handler bail, and with it every rejection vitest
// already catches — including one leaked at module scope in a file whose
// cases are all skipped, where no hook of ours would ever run. All this does
// is hold the file open past its last case.
//
// vitest 4.1.10 also ships `--detectAsyncLeaks`, which names the dangling
// promise and its line without waiting for it to settle. It is off by
// default and does not fail the run, so it stays a debugging aid: this is
// what makes the run red.
import { afterAll } from "vitest";
import { resolveClosingWindowMs } from "./closing-window";

const env = (
  globalThis as unknown as {
    process: { env: Record<string, string | undefined> };
  }
).process.env;

// A rejection scheduled beyond the window still escapes. The controls widen
// it so their fixtures are not racing worker teardown; every real test file
// gets the default, which `closing-window.ts` pins.
const CLOSING_WINDOW_MS = resolveClosingWindowMs(env.KENDEX_CLOSING_WINDOW_MS);

// Captured before any test can call `vi.useFakeTimers()`: a wait on a fake
// clock nobody advances never returns.
const realSetTimeout = globalThis.setTimeout.bind(globalThis);

afterAll(
  () =>
    new Promise<void>((resolve) => realSetTimeout(resolve, CLOSING_WINDOW_MS)),
);
