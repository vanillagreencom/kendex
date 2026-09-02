// The control for `unhandled-rejections.ts`, which claims two things: a
// rejection settling after the file ends now reddens the run, and one
// settling while the file runs still reddens it exactly as before. Each is a
// fixture run under both configs — `guarded` carries the setup file,
// `unguarded` does not — so the guarded verdict is read against a measured
// baseline rather than against a comment. The fake-timers fixture is the
// exception, guarded only: without the closing window there is nothing there
// to hang.
//
// Each run is a real `vitest run` in its own process: the closing window is
// a property of how a worker is torn down, which nothing nested in this one
// can observe.
//
// Node's builtins are reached through `process.getBuiltinModule` and a local
// shape. `ui/` has no `@types/node` — its own code ships to a webview — and
// an ambient `declare module` is not scoped to tests: `tsconfig.json`
// includes all of `src`, so declaring one would hand node's builtins to the
// app tree as well.
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
    };
  }
).process;

const { spawnSync } = node.getBuiltinModule("node:child_process");
const { fileURLToPath } = node.getBuiltinModule("node:url");

// Resolved as URLs and converted once: a `.pathname` keeps a checkout path's
// spaces percent-encoded, and on Windows leads with a slash before the drive.
const UI_ROOT = fileURLToPath(new URL("../..", import.meta.url));
const VITEST = fileURLToPath(
  new URL("../../node_modules/vitest/vitest.mjs", import.meta.url),
);

// The spawn gives up first, so a child that overran is reported as the
// child's ETIMEDOUT rather than as this case running out of clock.
const SPAWN_TIMEOUT_MS = 45_000;
const CASE_TIMEOUT_MS = 60_000;

/** One fixture under one config, as a real nested `vitest run`. Vitest marks
 *  its workers through the environment, so a child that inherited ours would
 *  take itself for part of this run. */
function runFixture(
  config: "guarded" | "unguarded",
  fixture: string,
): { status: number | null; output: string } {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(node.env)) {
    if (value !== undefined && !key.startsWith("VITEST")) env[key] = value;
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
      expect(run.status).toBe(0);
    },
    CASE_TIMEOUT_MS,
  );

  it(
    "reddens the run once the closing window holds the file open",
    () => {
      const run = runFixture("guarded", "late-rejection");
      expect(run.output).toContain("Unhandled Rejection");
      expect(run.output).toContain("late rejection fixture");
      expect(run.output).toContain("Errors  1 error");
      expect(run.status).toBe(1);
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
      expect(run.status).toBe(1);
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
      // Both cases pass: the rejection reddens the file, never a case.
      expect(run.output).toContain("Tests  2 passed (2)");
      expect(run.output).toContain("Errors  1 error");
      // Vitest's hedge, which the closing window must not talk over.
      expect(run.output).toContain(
        "It doesn't mean the error was thrown inside the file itself",
      );
      expect(run.status).toBe(1);
    },
  );
});

describe("a case that leaves fake timers installed", () => {
  it(
    "still reaches a verdict, because the window waits on the real clock",
    () => {
      const run = runFixture("guarded", "fake-timers");
      expect(run.output).toContain("Test Files  1 passed (1)");
      expect(run.status).toBe(0);
    },
    CASE_TIMEOUT_MS,
  );
});
