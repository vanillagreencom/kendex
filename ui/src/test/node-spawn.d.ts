// The UI has no `@types/node`: its own code runs in a browser, and pulling
// node's types in would change what `setTimeout` returns across the whole
// tree. This is the one thing a test needs that has no browser equivalent —
// running a nested vitest — and nothing else.
declare module "node:child_process" {
  export function spawnSync(
    command: string,
    args: readonly string[],
    options: {
      cwd: string;
      encoding: "utf8";
      env: Record<string, string>;
      timeout: number;
    },
  ): { status: number | null; stdout: string; stderr: string };
}
