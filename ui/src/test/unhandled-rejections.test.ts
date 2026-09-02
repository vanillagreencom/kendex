// The control for `unhandled-rejections.ts`, which claims two things: a
// rejection settling after the file ends now reddens the run, and one
// settling while the file runs still reddens it exactly as before. Each is a
// fixture run under both configs — `guarded` carries the setup file,
// `unguarded` does not — so the guarded verdict is read against a measured
// baseline. The fake-timers fixture is the exception, guarded only: without
// the closing window there is nothing there to hang.
//
// Each run is a real `vitest run` in its own process: the closing window is
// a property of how a worker is torn down, which nothing nested in this one
// can observe.
//
// Node's builtins come through `process.getBuiltinModule` and a local shape.
// `ui/` has no `@types/node`, and an ambient `declare module` is not scoped
// to tests: `tsconfig.json` includes all of `src`, so one would hand node's
// builtins to the app tree too.
import { describe, expect, it } from "vitest";

type SpawnResult = {
  status: number | null;
  signal: string | null;
  error?: Error;
  stdout: string;
  stderr: string;
};

const node = (
  globalThis as unknown as {
    process: {
      execPath: string;
      env: Record<string, string | undefined>;
      getBuiltinModule(id: "node:child_process"): {
        spawnSync(
          command: string,
          args: readonly string[],
          options: {
            cwd: string;
            encoding: "utf8";
            env: Record<string, string>;
            timeout: number;
          },
        ): SpawnResult;
      };
      getBuiltinModule(id: "node:url"): {
        fileURLToPath(url: URL): string;
      };
      getBuiltinModule(id: "node:fs"): {
        readdirSync(path: string): string[];
      };
    };
  }
).process;

const { spawnSync } = node.getBuiltinModule("node:child_process");
const { fileURLToPath } = node.getBuiltinModule("node:url");
const { readdirSync } = node.getBuiltinModule("node:fs");

// Converted from URLs, not read off `.pathname`, which keeps a path's spaces
// percent-encoded and leads with a slash before a Windows drive letter.
const UI_ROOT = fileURLToPath(new URL("../..", import.meta.url));
const VITEST = fileURLToPath(
  new URL("../../node_modules/vitest/vitest.mjs", import.meta.url),
);

// The spawn gives up first, so an overrunning child reports its own
// ETIMEDOUT rather than this case running out of clock.
const SPAWN_TIMEOUT_MS = 45_000;
const CASE_TIMEOUT_MS = 60_000;

// Twice the late-rejection fixture's delay, which is all this side needs:
// both are timers in one process, fired in expiry order whatever the load.
const WIDE_WINDOW_MS = 1500;

type Run = { status: number | null; output: string };

// The status assertions pass the child's whole output as `expect`'s message
// argument, because a number would not show it. The output assertions do not:
// a failing `toContain` already prints the whole subject.

/** One fixture under one config, as a real nested `vitest run`. Vitest marks
 *  its workers through the environment, so a child that inherited ours would
 *  take itself for part of this run. */
function runFixture(
  config: "guarded" | "unguarded",
  fixture: string,
  closingWindowMs?: number,
): Run {
  // The window comes from the case, never from the environment this run was
  // started in: an exported KENDEX_CLOSING_WINDOW_MS would otherwise ride
  // into every nested run that declares none.
  const env: Record<string, string> = {};
  const ambient = /^(VITEST|KENDEX_CLOSING_WINDOW_MS$)/;
  for (const [key, value] of Object.entries(node.env)) {
    if (value !== undefined && !ambient.test(key)) env[key] = value;
  }
  if (closingWindowMs !== undefined) {
    env.KENDEX_CLOSING_WINDOW_MS = String(closingWindowMs);
  }
  const run = spawnSync(
    node.execPath,
    [
      VITEST,
      "run",
      "--config",
      `src/test/fixtures/${config}.config.ts`,
      fixture,
    ],
    { cwd: UI_ROOT, encoding: "utf8", env, timeout: SPAWN_TIMEOUT_MS },
  );
  // Without this the operator reads a diff against "undefinedundefined"
  // instead of the ENOENT or ETIMEDOUT that says why nothing ran.
  if (run.error) throw run.error;
  return { status: run.status, output: `${run.stdout}${run.stderr}` };
}

describe("a rejection that settles after the file ended", () => {
  it(
    "is dropped by vitest on its own",
    () => {
      const run = runFixture("unguarded", "late-rejection");
      expect(run.output).toContain("Test Files  1 passed (1)");
      expect(run.output).not.toContain("late rejection fixture");
      expect(run.status, run.output).toBe(0);
    },
    CASE_TIMEOUT_MS,
  );

  it(
    "reddens the run once the closing window holds the file open",
    () => {
      const run = runFixture("guarded", "late-rejection", WIDE_WINDOW_MS);
      expect(run.output).toContain("Unhandled Rejection");
      expect(run.output).toContain("late rejection fixture");
      expect(run.output).toContain("Errors  1 error");
      expect(run.status, run.output).toBe(1);
    },
    CASE_TIMEOUT_MS,
  );
});

describe("a rejection no hook of ours could reach", () => {
  it.for(["unguarded", "guarded"] as const)(
    "is reported under the %s config, module scope and every case skipped",
    { timeout: CASE_TIMEOUT_MS },
    (config) => {
      const run = runFixture(config, "skipped-file");
      expect(run.output).toContain("Unhandled Rejection");
      expect(run.output).toContain("skipped file fixture");
      expect(run.output).toContain("Test Files  1 skipped (1)");
      expect(run.status, run.output).toBe(1);
    },
  );
});

describe("a rejection that lands while a later case is running", () => {
  it.for(["unguarded", "guarded"] as const)(
    "reddens the file under the %s config, blaming no case",
    { timeout: CASE_TIMEOUT_MS },
    (config) => {
      const run = runFixture(config, "mid-file-rejection");
      expect(run.output).toContain("Unhandled Rejection");
      expect(run.output).toContain("mid-file rejection fixture");
      expect(run.output).toContain("Tests  2 passed (2)");
      expect(run.output).toContain("Errors  1 error");
      expect(run.output).toContain(
        "It doesn't mean the error was thrown inside the file itself",
      );
      expect(run.status, run.output).toBe(1);
    },
  );
});

describe("a case that leaves fake timers installed", () => {
  it(
    "still reaches a verdict, because the window waits on the real clock",
    () => {
      const run = runFixture("guarded", "fake-timers");
      expect(run.output).toContain("Test Files  1 passed (1)");
      expect(run.status, run.output).toBe(0);
    },
    CASE_TIMEOUT_MS,
  );
});

describe("an exported KENDEX_CLOSING_WINDOW_MS", () => {
  it(
    "does not reach a run that declared no window",
    () => {
      // 15s is past vitest's 10s hook timeout, so a child that read it would
      // die on "Hook timed out in 10000ms" instead of passing at the default.
      node.env.KENDEX_CLOSING_WINDOW_MS = "15000";
      try {
        const run = runFixture("guarded", "fake-timers");
        expect(run.output).toContain("Test Files  1 passed (1)");
        expect(run.status, run.output).toBe(0);
      } finally {
        delete node.env.KENDEX_CLOSING_WINDOW_MS;
      }
    },
    CASE_TIMEOUT_MS,
  );
});

// Every control above passes `--config`, so none of them reads the config a
// plain `vitest run` resolves — and vitest prefers `vitest.config.*` over
// `vite.config.ts`. Measured: with a `vitest.config.ts` present that does not
// carry `setupFiles`, a real test file runs at `setup 0ms` while every
// control here stays green. No fixture can be pointed at the resolved config
// — vitest has no `--include` flag and the default include never matches a
// `*.fixture.ts` — so what is pinned is that nothing shadows it.
describe("the config a plain vitest run resolves", () => {
  it("is the one the controls pin, unshadowed", () => {
    const shadows = readdirSync(UI_ROOT).filter((name) =>
      name.startsWith("vitest.config."),
    );
    expect(shadows).toEqual([]);
  });
});
