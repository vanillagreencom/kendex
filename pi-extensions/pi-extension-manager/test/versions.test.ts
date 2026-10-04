import { afterAll, expect, test } from "bun:test";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pendingRequest, respond } from "./fixtures/http.ts";
import { mutantManager, settleWithin, startedPid, writeCommand } from "./fixtures/commands.ts";

// A disposable copy keeps the network and clock local to this surface. No SDK mock or global timers.
const root = join(process.cwd(), "tmp", "manager-versions-tests");
mkdirSync(root, { recursive: true });
const manager = resolve(import.meta.dir, "../extensions/manager");
let source = readFileSync(join(manager, "versions.ts"), "utf8");
for (const [before, after] of [
	['from "./paths.js"', `from ${JSON.stringify(join(manager, "paths.ts"))}`],
	['from "./process.js"', `from ${JSON.stringify(join(manager, "process.ts"))}`],
	['from "./types.js"', `from ${JSON.stringify(join(manager, "types.ts"))}`],
	['from "node:https"', `from ${JSON.stringify(join(import.meta.dir, "fixtures/http.ts"))}`],
	['NPM_CHECK_TIMEOUT_MS = 4_000', 'NPM_CHECK_TIMEOUT_MS = 5'],
]) {
	expect(source.split(before).length - 1).toBe(1);
	source = source.replace(before, after);
}
writeFileSync(join(root, "versions.ts"), source);
const { fetchNpmLatest } = await import(join(root, "versions.ts"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

// Real waits verify the deadline scheduler. A short bound in the copy avoids a multi-second test.
test("npm check enforces a total deadline even with response data arriving", async () => {
	const pending = fetchNpmLatest("example", new AbortController().signal);
	const res = respond();
	res.emit("data", Buffer.from("{"));
	await expect(pending).rejects.toThrow("npm check deadline exceeded");
	expect(pendingRequest().destroyedCount).toBe(1);
	expect(res.destroyedCount).toBe(1);
});

test("npm check caps response bytes before buffering them", async () => {
	const pending = fetchNpmLatest("example", new AbortController().signal);
	const res = respond();
	res.emit("data", Buffer.alloc(256 * 1024 + 1));
	await expect(pending).rejects.toThrow("npm response byte limit exceeded");
	expect(pendingRequest().destroyedCount).toBe(1);
	expect(res.destroyedCount).toBe(1);
});

test("npm check rejects request and response errors and cancellation", async () => {
	for (const row of ["request", "response", "aborted", "cancelled", "status"] as const) {
		const owner = new AbortController();
		const pending = fetchNpmLatest("example", owner.signal);
		if (row === "request") pendingRequest().emit("error", new Error("request failed"));
		else if (row === "cancelled") owner.abort();
		else {
			const res = respond(row === "status" ? 503 : 200);
			if (row === "response") res.emit("error", new Error("response failed"));
			if (row === "aborted") res.emit("aborted");
		}
		expect(pendingRequest().destroyedCount).toBe(1);
		await expect(pending).rejects.toThrow();
	}
});

test("npm check parses a complete bounded response", async () => {
	const pending = fetchNpmLatest("example", new AbortController().signal);
	const res = respond();
	res.emit("data", Buffer.from('{"version":"2.0.0"}'));
	res.emit("end");
	expect(await pending).toBe("2.0.0");
	expect(pendingRequest().destroyedCount).toBe(0);
});

type VersionsModule = typeof import("../extensions/manager/versions.ts");

// npm-root discovery runs a fake `npm` first on PATH; the user scope's one
// expensive lookup is `npm root -g`, reached once the cheap Pi npm root misses.
async function withFakeNpm<T>(body: string, run: (pidFile: string) => Promise<T>): Promise<T> {
	const scratch = join(root, `npm-root-${Math.random()}`);
	const bin = join(scratch, "bin");
	writeCommand(join(bin, "npm"), body.replaceAll("$SCRATCH", scratch));
	const saved = { PATH: process.env.PATH, NPM_CONFIG_PREFIX: process.env.NPM_CONFIG_PREFIX, npm_config_prefix: process.env.npm_config_prefix };
	process.env.PATH = [bin, "/usr/bin", "/bin"].join(":");
	delete process.env.NPM_CONFIG_PREFIX;
	delete process.env.npm_config_prefix;
	try {
		return await run(join(scratch, "pid"));
	} finally {
		for (const [name, value] of Object.entries(saved)) {
			if (value === undefined) delete process.env[name];
			else process.env[name] = value;
		}
	}
}

function lookup(versions: VersionsModule, signal: AbortSignal) {
	const baseDir = join(root, "agent");
	return versions.resolveNpmPackageDir(signal, "@scope/rooted", "user", baseDir, root);
}

test("npm root lookups find the package or name each failed lookup", async () => {
	const versions = await import("../extensions/manager/versions.ts");
	const globalRoot = join(root, "global-root");
	const packageDir = join(globalRoot, "@scope", "rooted");
	mkdirSync(packageDir, { recursive: true });
	writeFileSync(join(packageDir, "package.json"), "{}");
	const rows = [
		{ body: `echo "${globalRoot}"`, expected: { kind: "found", dir: packageDir } },
		{ body: "exit 3", expected: { kind: "missing", lookupFailures: ["npm root -g: exit=3"] } },
		{ body: "kill -ABRT $$", expected: { kind: "missing", lookupFailures: ["npm root -g: exit=SIGABRT"] } },
		{ body: "true", expected: { kind: "missing", lookupFailures: ["npm root -g: printed no root"] } },
	];
	for (const row of rows) {
		expect(await withFakeNpm(row.body, () => lookup(versions, new AbortController().signal))).toEqual(row.expected);
	}
});

async function abortedLookup(versions: VersionsModule): Promise<unknown> {
	return withFakeNpm('echo $$ > "$SCRATCH/pid"; exec sleep 30', async (pidFile) => {
		const session = new AbortController();
		const pending = lookup(versions, session.signal);
		const pid = await startedPid(pidFile);
		session.abort();
		try {
			// A working lookup ends inside the runner's SIGTERM grace; one still
			// running at this bound never received the session's abort.
			return await settleWithin(pending, 4_000);
		} finally {
			try { process.kill(-pid, "SIGKILL"); } catch {}
		}
	});
}

test("ending the session stops a running npm root lookup; control: a lookup spawned without the signal keeps running", async () => {
	expect(await abortedLookup(await import("../extensions/manager/versions.ts"))).toEqual({ kind: "missing", lookupFailures: ["npm root -g: cancelled=cancelled"] });
	const mutant = mutantManager(join(root, "mutant-npm-root"), [{
		file: "versions.ts",
		before: "{ cwd, deadlineMs: NPM_ROOT_DEADLINE_MS, signal }",
		after: "{ cwd, deadlineMs: NPM_ROOT_DEADLINE_MS, signal: new AbortController().signal }",
	}]);
	expect(await abortedLookup(await import(join(mutant, "versions.ts")))).toBe("unsettled");
}, 20_000);
