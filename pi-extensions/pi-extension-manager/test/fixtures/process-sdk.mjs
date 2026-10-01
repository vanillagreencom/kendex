import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const [source, root, sdk] = process.argv.slice(2);
assert(source && root && sdk);
const require = createRequire(join(sdk, "package.json"));
const { createJiti } = await import(pathToFileURL(require.resolve("jiti")).href);
const { execCommand } = await import(pathToFileURL(join(sdk, "dist/core/exec.js")).href);
const jiti = createJiti(import.meta.url, { moduleCache: false, fsCache: false });
const { runCommand } = await jiti.import(join(source, "manager/process.ts"));
const { runUninstall } = await jiti.import(join(source, "manager/actions.ts"));
const pi = { exec: (command, args, options) => execCommand(command, args, options?.cwd ?? root, options) };
const owner = new AbortController();
const options = { signal: owner.signal, timeout: 4_000, cwd: root };
for (const code of [0, 7]) {
	const result = await runCommand(pi, process.execPath, ["-e", `process.stdout.write('output'); process.stderr.write('notice'); process.exit(${code})`], options);
	assert.equal(result.ok, code === 0, `sdk-exit: ${code}`);
	if (result.ok) assert.deepEqual(result, { ok: true, stdout: "output", stderr: "notice" });
	else assert.equal(result.cause, "exit");
}
const missing = await runCommand(pi, join(root, "not-installed"), [], options);
assert.equal(missing.ok, false, "sdk-launch: missing executable");
// Kill the completion shell itself: ExecResult reports zero with no footer.
const shellCrash = await runCommand(pi, process.execPath, ["-e", "process.kill(process.ppid, 'SIGTERM')"], options);
assert.equal(shellCrash.ok, false, "sdk-completion: missing proof");
assert.equal(shellCrash.cause, "exit");
// Real waits exercise SDK signals. The child ends itself to avoid a surviving descendant.
for (const mode of ["timeout", "cancelled"]) {
	const controller = new AbortController();
	const timer = mode === "cancelled" ? setTimeout(() => controller.abort(), 20) : undefined;
	const result = await runCommand(pi, process.execPath, ["-e", "setTimeout(() => {}, 200)"], { cwd: root, signal: controller.signal, timeout: mode === "timeout" ? 20 : 4_000 });
	clearTimeout(timer);
	assert.equal(result.ok, false, `sdk-interruption: ${mode}`);
	assert.equal(result.cause, mode);
}
process.env.NODE_OPTIONS = "--max-old-space-size=1";
const reference = spawnSync("npm", ["root"], { cwd: root, env: { PATH: process.env.PATH, HOME: root, NODE_OPTIONS: process.env.NODE_OPTIONS }, encoding: "utf8", timeout: 4_000 });
assert.equal(reference.status, null, "sdk-npm: heap crash reference");
assert.notEqual(reference.signal, null, "sdk-npm: heap crash signal");
const npmCrash = await runCommand(pi, "npm", ["root"], options);
assert.equal(npmCrash.ok, false, "sdk-npm: crashed command cannot succeed");
assert.equal(npmCrash.cause, "exit");
const baseDir = join(root, "agent");
mkdirSync(baseDir, { recursive: true });
const path = join(baseDir, "settings.json");
const json = { packages: ["npm:example"] };
const before = JSON.stringify(json);
writeFileSync(path, before);
const settingsFiles = [{ scope: "user", path, baseDir, exists: true, json }];
const item = { id: "package:user:npm:example:example", displayName: "example", kind: "package", scope: "user", packageName: "example", sourceName: "npm:example", sourcePath: "npm:example" };
const plan = { item, method: { kind: "npm", npmName: "example", scope: "user", cwd: root, command: "npm", argsPrefix: [] } };
const result = await runUninstall(pi, plan, { settingsFiles });
assert.equal(readFileSync(path, "utf8"), before, "sdk-uninstall: settings preserved");
assert.deepEqual(json.packages, ["npm:example"], "sdk-uninstall: in-memory settings preserved");
assert.equal(result.ok, false, "sdk-uninstall: heap crash cannot succeed");
console.log(JSON.stringify({ npmSignal: reference.signal, settingsPreserved: true }));
