import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, test } from "vitest";

const ui = fileURLToPath(new URL(".", import.meta.url));
const packageJson = JSON.parse(readFileSync(join(ui, "package.json"), "utf8"));
const biome = JSON.parse(readFileSync(join(ui, "biome.json"), "utf8"));

function lint(source: string, config = biome, script = packageJson.scripts["check:lint"]) {
  const root = mkdtempSync(join(tmpdir(), "kendex-lint-"));
  try {
    mkdirSync(join(root, "src"));
    writeFileSync(join(root, "src", "input.ts"), source);
    writeFileSync(join(root, "biome.json"), JSON.stringify(config));
    writeFileSync(join(root, "package.json"), JSON.stringify({ scripts: { "check:lint": script } }));
    const npm = process.env.npm_execpath;
    if (!npm) throw new Error("npm_execpath is unavailable");
    const result = spawnSync(process.execPath, [npm, "run", "check:lint", "--", "--reporter=json"], {
      cwd: root,
      env: {
        PATH: `${join(ui, "node_modules", ".bin")}${delimiter}${process.env.PATH ?? ""}`,
        HOME: root,
        ...(process.env.SystemRoot ? { SystemRoot: process.env.SystemRoot } : {}),
      },
      encoding: "utf8",
      timeout: 10_000,
    });
    if (result.error) throw result.error;
    const report = JSON.parse(result.stdout.slice(result.stdout.indexOf("{")));
    return { status: result.status, diagnostics: report.diagnostics as { category: string; severity: string }[] };
  } finally {
    rmSync(root, { recursive: true });
  }
}

test.each([
  ["formatting", "export const value={key:1};", null],
  ["style", 'export function label(value: string) { return "label:" + value; }', "lint/style/useTemplate"],
  ["behavior", "export function broken() { debugger; }", "lint/suspicious/noDebugger"],
] as const)("lint severity: %s", (kind, source, category) => {
  const result = lint(source);
  expect(result.status).toBe(kind === "behavior" ? 1 : 0);
  if (category) {
    expect(result.diagnostics).toEqual(expect.arrayContaining([
      expect.objectContaining({ category, severity: kind === "behavior" ? "error" : "warning" }),
    ]));
  }

  if (kind === "formatting") {
    expect(lint(source, biome, "biome check src").status).toBe(1);
  } else {
    const config = structuredClone(biome);
    if (kind === "style") config.linter.rules.style = "error";
    else config.linter.rules.suspicious.noDebugger = "off";
    expect(lint(source, config).status).toBe(kind === "style" ? 1 : 0);
  }
});
