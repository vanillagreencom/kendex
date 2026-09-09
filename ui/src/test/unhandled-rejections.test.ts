// The control for `unhandled-rejections.ts`, which claims two things: a
// rejection settling after the file ends reddens the run, and one settling
// while the file runs reddens it too. Each is a fixture run under both
// configs — `guarded` carries the setup file, `unguarded` does not — so the
// guarded verdict is read against a measured baseline.
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
    };
  }
).process;

const { spawnSync } = node.getBuiltinModule("node:child_process");
const { fileURLToPath } = node.getBuiltinModule("node:url");

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

// CI paints this output and no local environment reproduces it — measured
// here across CI, FORCE_COLOR, TERM and a TTY-less spawn, all of them plain.
// The escapes land inside the very summary lines the cases match on, so a
// `toContain` misses text that renders correctly. Normalising the capture is
// what lets every assertion below read what a person reads in the log.
//
// One shape covers it: CSI, `ESC [` then parameters then a final byte, which
// is both the colour and the reporter's cursor moves. ESC comes from its code
// point because a control character typed into a regex reads as nothing.
const ESC = String.fromCharCode(27);
const ANSI = new RegExp(`${ESC}\\[[0-9;?]*[ -/]*[@-~]`, "g");

/** The captured output as it renders, with any colour taken out. */
function rendered(output: string): string {
  return output.replace(ANSI, "");
}

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
  // Belt to `rendered`'s braces: tinyrainbow, which paints vitest's reporter,
  // turns colour off whenever NO_COLOR is in the environment at all — before
  // it consults FORCE_COLOR, a TTY, or the CI flag that is the likeliest
  // trigger here. So the escapes are usually never emitted.
  env.NO_COLOR = "1";
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
  return {
    status: run.status,
    output: rendered(`${run.stdout}${run.stderr}`),
  };
}

describe("a rejection that settles after the file ended", () => {
  const rows: {
    name: string;
    config: "unguarded" | "guarded";
    closingWindowMs?: number;
    status: number;
    present: string[];
    absent: string[];
  }[] = [
    {
      name: "is dropped by vitest on its own",
      config: "unguarded",
      status: 0,
      present: ["Test Files  1 passed (1)"],
      absent: ["late rejection fixture"],
    },
    {
      name: "reddens the run once the closing window holds the file open",
      config: "guarded",
      closingWindowMs: WIDE_WINDOW_MS,
      status: 1,
      present: [
        "Unhandled Rejection",
        "late rejection fixture",
        "Errors  1 error",
      ],
      absent: [],
    },
  ];
  it("keeps the late-rejection table nonempty", () => {
    expect(rows.length, "late-rejection table is empty").toBeGreaterThan(0);
  });
  it.for(rows.map((row) => [row.name, row] as const))(
    "%s",
    { timeout: CASE_TIMEOUT_MS },
    ([, row]) => {
      const run = runFixture(row.config, "late-rejection", row.closingWindowMs);
      expect(
        {
          status: run.status,
          requiredTokensFound: row.present.filter((token) =>
            run.output.includes(token),
          ),
          forbiddenTokensFound: row.absent.filter((token) =>
            run.output.includes(token),
          ),
        },
        `${row.name}\n${run.output}`,
      ).toEqual({
        status: row.status,
        requiredTokensFound: row.present,
        forbiddenTokensFound: [],
      });
    },
  );
});

describe("a rejection no hook of ours could reach", () => {
  const configs = ["unguarded", "guarded"] as const;
  it("keeps the skipped-file config table nonempty", () => {
    expect(
      configs.length,
      "skipped-file config table is empty",
    ).toBeGreaterThan(0);
  });
  it.for(configs)(
    "is reported under the %s config, module scope and every case skipped",
    { timeout: CASE_TIMEOUT_MS },
    (config) => {
      const run = runFixture(config, "skipped-file");
      expect(
        {
          unhandled: run.output.includes("Unhandled Rejection"),
          fixture: run.output.includes("skipped file fixture"),
          skipped: run.output.includes("Test Files  1 skipped (1)"),
          status: run.status,
        },
        `${config}\n${run.output}`,
      ).toEqual({ unhandled: true, fixture: true, skipped: true, status: 1 });
    },
  );
});

describe("a rejection that lands while a later case is running", () => {
  const configs = ["unguarded", "guarded"] as const;
  it("keeps the mid-file config table nonempty", () => {
    expect(configs.length, "mid-file config table is empty").toBeGreaterThan(0);
  });
  it.for(configs)(
    "reddens the file under the %s config, blaming no case",
    { timeout: CASE_TIMEOUT_MS },
    (config) => {
      const run = runFixture(config, "mid-file-rejection");
      expect(
        {
          unhandled: run.output.includes("Unhandled Rejection"),
          fixture: run.output.includes("mid-file rejection fixture"),
          casesPassed: run.output.includes("Tests  2 passed (2)"),
          errorCount: run.output.includes("Errors  1 error"),
          attribution: run.output.includes(
            "It doesn't mean the error was thrown inside the file itself",
          ),
          status: run.status,
        },
        `${config}\n${run.output}`,
      ).toEqual({
        unhandled: true,
        fixture: true,
        casesPassed: true,
        errorCount: true,
        attribution: true,
        status: 1,
      });
    },
  );
});

// The one control for `rendered`, because every case above depends on it
// and none of them would notice it gone: on this machine the capture carries
// no colour, so they stay green either way. The sample is the shape CI
// paints — the `RUN` banner, and the summary lines the cases match on,
// painted where vitest paints them. Take the strip out and the escapes sit
// between the words, and each `toContain` here misses.
describe("the colour CI puts in the captured output", () => {
  it("normalises to the text every case above asserts", () => {
    const coloured =
      `\n${ESC}[1m${ESC}[30m${ESC}[46m RUN ${ESC}[39m${ESC}[49m${ESC}[22m v4.1.10\n` +
      ` Test Files  ${ESC}[1m${ESC}[32m1 passed${ESC}[39m${ESC}[22m (1)\n` +
      ` Tests  ${ESC}[1m${ESC}[32m2 passed${ESC}[39m${ESC}[22m (2)\n` +
      ` Errors  ${ESC}[1m${ESC}[31m1 error${ESC}[39m${ESC}[22m\n`;

    const text = rendered(coloured);
    expect(text).toContain("Test Files  1 passed (1)");
    expect(text).toContain("Tests  2 passed (2)");
    expect(text).toContain("Errors  1 error");
    expect(text).not.toContain(ESC);
  });
});
