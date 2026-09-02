// The control for `unhandled-rejections.ts`. The guard's whole claim is
// about a run vitest reports as passing, so the late-rejection fixture is
// run twice: without the guard the run is green, with it the run is red and
// names the rejection. The green half is what stops the red half from being
// vacuous — it is the case that goes red if vitest ever closes the gap
// upstream, or if the fixture stops being the shape the guard is for.
//
// The mid-file fixture covers what vitest already did and the guard now
// owns, since taking Node's listener silences vitest's own report: a
// rejection landing inside the file still fails, and now names the case
// that leaked it rather than the case that happened to be running.
//
// Each run is a real `vitest run` in its own process. Nested in-process is
// not an option: this worker already holds the guard's listeners, which is
// exactly the state the runs have to differ on.
import { spawnSync } from "node:child_process";
import { describe, expect, it } from "vitest";

const UI_ROOT = new URL("../..", import.meta.url).pathname;
const VITEST = `${UI_ROOT}node_modules/vitest/vitest.mjs`;
const RUN_TIMEOUT_MS = 60_000;

const parent = (
  globalThis as unknown as {
    process: { execPath: string; env: Record<string, string | undefined> };
  }
).process;

/** One fixture under one config, as a real nested `vitest run`. Vitest
 *  marks its workers through the environment, so a child that inherited
 *  ours would take itself for part of this run. */
function runFixture(
  config: string,
  fixture: string,
): { status: number | null; output: string } {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(parent.env)) {
    if (value !== undefined && !key.startsWith("VITEST")) env[key] = value;
  }
  const run = spawnSync(
    parent.execPath,
    [
      VITEST,
      "run",
      "--config",
      `src/test/fixtures/${config}.config.ts`,
      fixture,
    ],
    { cwd: UI_ROOT, encoding: "utf8", env, timeout: RUN_TIMEOUT_MS },
  );
  return { status: run.status, output: `${run.stdout}${run.stderr}` };
}

describe("a rejection that settles after its case returned", () => {
  it(
    "is dropped by vitest on its own",
    () => {
      const run = runFixture("unguarded", "late-rejection");
      expect(run.output).toContain("1 passed");
      expect(run.output).not.toContain("late rejection fixture");
      expect(run.status).toBe(0);
    },
    RUN_TIMEOUT_MS,
  );

  it(
    "fails the file once the guard is set up",
    () => {
      const run = runFixture("guarded", "late-rejection");
      expect(run.output).toContain(
        "1 unhandled promise rejection after the last test in this file",
      );
      expect(run.output).toContain("late rejection fixture");
      expect(run.status).not.toBe(0);
    },
    RUN_TIMEOUT_MS,
  );
});

describe("a rejection that settles while the file is still running", () => {
  it(
    "fails the case that leaked it, not the one running when it landed",
    () => {
      const run = runFixture("guarded", "mid-file-rejection");
      expect(run.output).toContain(
        "1 unhandled promise rejection in this test",
      );
      expect(run.output).toContain("mid-file rejection fixture");
      expect(run.output).toContain("leaks a rejection its own case outlives");
      expect(run.output).toContain("1 failed | 1 passed");
      expect(run.status).not.toBe(0);
    },
    RUN_TIMEOUT_MS,
  );
});
