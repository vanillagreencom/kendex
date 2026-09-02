// Vitest reports an unhandled rejection only while the file that started it
// is still running. A promise that rejects after its case has returned is
// dropped: the worker process holding the pending timer is destroyed when
// the file ends, so the rejection never happens and nothing ever reads it.
// A run that is green while a file leaks six rejections is the same failure
// as a control that will not go red.
//
// This setup file owns the signal for every test file. Two things follow
// from taking Node's `unhandledRejection` listener: Vitest steps back (its
// own handler bails as soon as a second listener exists), so what is
// reported here is all that is reported; and the report can be tighter than
// Vitest's, which names the last case to have run rather than the case that
// leaked.
//
// - After each case, one pass of the event loop, then anything Node flagged
//   fails that case.
// - After the last case, the file is held open for CLOSING_WINDOW_MS so
//   work it left running gets its chance to reject inside the worker's
//   lifetime, and anything flagged fails the file.
//
// A rejection scheduled beyond that window still escapes — once the worker
// is gone there is no signal to read, in this file or anywhere else.
import { afterAll, afterEach } from "vitest";

/** How long the file stays open after its last case. Long enough for the
 *  async shape this catches — a mocked command's promise rejecting a turn
 *  or two behind the case that called it — without holding every file open
 *  for work that is not coming. */
const CLOSING_WINDOW_MS = 50;

// Captured before any test can call `vi.useFakeTimers()`, which replaces
// the global: a drain that waits on a fake clock nobody advances hangs.
const realSetTimeout = globalThis.setTimeout.bind(globalThis);
const wait = (ms: number) =>
  new Promise<void>((resolve) => realSetTimeout(resolve, ms));

/** Rejections Node has flagged as having no handler, keyed by the promise
 *  so a handler attached late can take one back off the list. */
const flagged = new Map<Promise<unknown>, unknown>();

const onUnhandled = (reason: unknown, promise: Promise<unknown>) => {
  flagged.set(promise, reason);
};
const onHandled = (promise: Promise<unknown>) => {
  flagged.delete(promise);
};

// The UI has no `@types/node` — its own code runs in a browser — so the two
// process events this needs are reached through a local shape rather than
// by pulling node's types over the whole tree.
type Rejections = {
  on(event: "unhandledRejection", handler: typeof onUnhandled): void;
  on(event: "rejectionHandled", handler: typeof onHandled): void;
  off(event: "unhandledRejection", handler: typeof onUnhandled): void;
  off(event: "rejectionHandled", handler: typeof onHandled): void;
};
const node = (globalThis as unknown as { process: Rejections }).process;

// A worker can run more than one file, and each file loads this module
// afresh — with its own `flagged`. The listeners the previous load left
// behind write to a map nothing reads, so they come off first.
const SLOT = Symbol.for("kendex.unhandled-rejection-guard");
const slots = globalThis as unknown as Record<symbol, (() => void) | undefined>;
slots[SLOT]?.();
node.on("unhandledRejection", onUnhandled);
node.on("rejectionHandled", onHandled);
slots[SLOT] = () => {
  node.off("unhandledRejection", onUnhandled);
  node.off("rejectionHandled", onHandled);
};

/** Give pending work `ms` to settle, then one more pass of the event loop —
 *  Node flags a rejection at the end of the turn it settles in, not in it. */
async function drain(ms: number): Promise<void> {
  await wait(ms);
  await wait(0);
}

function reportAndClear(where: string): void {
  if (flagged.size === 0) return;
  const reasons = [...flagged.values()];
  flagged.clear();
  const detail = reasons
    .map((reason) =>
      reason instanceof Error
        ? (reason.stack ?? reason.message)
        : String(reason),
    )
    .join("\n\n");
  throw new Error(
    `${reasons.length} unhandled promise rejection${
      reasons.length === 1 ? "" : "s"
    } ${where}:\n\n${detail}`,
  );
}

afterEach(async () => {
  await drain(0);
  reportAndClear("in this test");
});

afterAll(async () => {
  await drain(CLOSING_WINDOW_MS);
  reportAndClear("after the last test in this file");
});
