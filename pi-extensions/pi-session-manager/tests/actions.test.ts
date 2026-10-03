import { expect, mock, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { sessionFixture } from "./lib/session-fixture.ts";

mock.module("@earendil-works/pi-coding-agent", () => ({ SessionManager: {} }));

interface TrashPaths {
	root: string;
	session: string;
	marker: string;
	claimPid: string;
}

// Each row is the `trash` on PATH: a script body, or none for a PATH whose bin
// directory holds no `trash`, so spawn emits "error". The hung row's helper
// sleeps past the 5 s deadline and then writes its marker: alive after the
// deadline, it is the helper that could still move the file. The real wait
// after the delete gives a surviving helper time to write that marker. The
// claiming row's trash starts another lane's Pi on the session, as a resume in
// that lane would, waits for its claim, then fails.
const rows = [
	{
		name: "a hung trash and its helper are killed at the deadline; the delete fails and keeps the file",
		trash: ({ marker }: TrashPaths) => `#!/bin/sh\n(sleep 6; touch '${marker}') &\nwait\n`,
		expected: { ok: false, method: "trash" },
		kept: true,
		helper: true,
	},
	{ name: "a trash that exits 1 falls through to unlink", trash: () => "#!/bin/sh\nexit 1\n", expected: { ok: true, method: "unlink" }, kept: false },
	{ name: "no trash on PATH falls through to unlink", trash: undefined, expected: { ok: true, method: "unlink" }, kept: false },
	{
		name: "a session another Pi claims while trash runs is refused when trash fails, keeping the file",
		trash: ({ root, session, claimPid }: TrashPaths) =>
			`#!/bin/sh\nenv -i PATH="$PATH" HOME='${root}' PI_CODING_AGENT_DIR='${root}/pi-agent' '${process.execPath}' --no-install '${join(import.meta.dir, "fixtures/claim-session.ts")}' '${root}' '${session}' 'claimed-id' > '${root}/claim.out' &\n` +
			`echo $! > '${claimPid}'\nuntil grep -q claimed '${root}/claim.out' 2>/dev/null; do sleep 0.05; done\nexit 1\n`,
		expected: { ok: false, method: "live" },
		kept: true,
	},
];

for (const row of rows) {
	test(row.name, async () => {
		const { clearPackageConfigCache } = await import("../extensions/package-config.ts");
		const { deleteSessionFile } = await import("../extensions/actions.ts");
		const root = sessionFixture();
		const bin = join(root, "bin");
		mkdirSync(bin);
		const sessionPath = join(root, "session.jsonl");
		const paths = { root, session: sessionPath, marker: join(root, "helper-survived"), claimPid: join(root, "claim.pid") };
		if (row.trash) {
			writeFileSync(join(bin, "trash"), row.trash(paths));
			chmodSync(join(bin, "trash"), 0o755);
		}
		writeFileSync(sessionPath, "{}\n");

		const saved = { PATH: process.env.PATH, PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR };
		process.env.PATH = row.trash ? `${bin}:${saved.PATH ?? ""}` : bin;
		process.env.PI_CODING_AGENT_DIR = join(root, "pi-agent");
		clearPackageConfigCache();
		try {
			const started = performance.now();
			const result = await deleteSessionFile(sessionPath, root, "session-id");
			expect(performance.now() - started).toBeLessThan(9_000);
			expect(result).toMatchObject(row.expected);
			expect(existsSync(sessionPath)).toBe(row.kept);
			if (row.helper) {
				await new Promise((resolve) => setTimeout(resolve, Math.max(0, 8_000 - (performance.now() - started))));
				expect(existsSync(paths.marker)).toBe(false);
			}
		} finally {
			if (existsSync(paths.claimPid)) process.kill(Number(readFileSync(paths.claimPid, "utf8").trim()), "SIGKILL");
			for (const [key, value] of Object.entries(saved)) {
				if (value === undefined) delete process.env[key];
				else process.env[key] = value;
			}
			clearPackageConfigCache();
		}
	}, 20_000);
}

// Each row is a second lane's Pi, a child process that claimed `owned` under
// the id `owned-id` and is still running or was killed, and the session this
// lane then deletes. The per-session kendex tree of the deleted id stands in
// for the state other extensions keep there.
const ownerRows = [
	{ name: "a session file another running Pi owns is refused with that Pi named", target: "owned", id: "other-id", alive: true, refused: true },
	{ name: "a session whose id another running Pi owns is refused, keeping the shared kendex tree", target: "other", id: "owned-id", alive: true, refused: true },
	{ name: "an unowned session beside a live one is deleted", target: "other", id: "other-id", alive: true, refused: false },
	{ name: "a claim whose Pi was killed is removed and does not block the delete", target: "owned", id: "other-id", alive: false, refused: false },
];

for (const row of ownerRows) {
	test(row.name, async () => {
		const { clearPackageConfigCache } = await import("../extensions/package-config.ts");
		const { deleteSessionFile } = await import("../extensions/actions.ts");
		const root = sessionFixture();
		const bin = join(root, "bin");
		mkdirSync(bin);
		writeFileSync(join(bin, "trash"), '#!/bin/sh\n/bin/rm -f "$@"\n');
		chmodSync(join(bin, "trash"), 0o755);
		const agentDir = join(root, "pi-agent");
		const laneB = join(root, "lane-b");
		const sessions = { owned: join(root, "owned.jsonl"), other: join(root, "other.jsonl") };
		writeFileSync(sessions.owned, "{}\n");
		writeFileSync(sessions.other, "{}\n");
		const target = sessions[row.target as keyof typeof sessions];
		const extensionState = join(agentDir, "kendex", "sessions", row.id, "pi-prompt-stash");
		mkdirSync(extensionState, { recursive: true });

		const child = Bun.spawn([process.execPath, "--no-install", join(import.meta.dir, "fixtures/claim-session.ts"), laneB, sessions.owned, "owned-id"], {
			env: { PATH: process.env.PATH, HOME: root, PI_CODING_AGENT_DIR: agentDir },
			stdout: "pipe",
			stderr: "inherit",
		});
		const saved = { PATH: process.env.PATH, PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR };
		try {
			const { value } = await child.stdout.getReader().read();
			expect(new TextDecoder().decode(value)).toBe("claimed\n");
			if (!row.alive) {
				child.kill("SIGKILL");
				await child.exited;
			}

			// A `trash` that removes the file: a delete that is not refused
			// succeeds there, so only the check before `trash` can refuse.
			process.env.PATH = bin;
			process.env.PI_CODING_AGENT_DIR = agentDir;
			clearPackageConfigCache();
			const result = await deleteSessionFile(target, root, row.id);

			if (row.refused) {
				expect(result).toEqual({
					ok: false,
					method: "live",
					owner: { pid: child.pid, cwd: laneB, sessionFile: sessions.owned, sessionId: "owned-id" },
					error: expect.stringContaining(laneB),
				});
			} else {
				expect(result).toEqual({ ok: true, method: "trash" });
			}
			expect(existsSync(target)).toBe(row.refused);
			expect(existsSync(extensionState)).toBe(row.refused);
			const claims = readdirSync(join(agentDir, "kendex", "pi-session-manager", "live"));
			expect(claims.length).toBe(row.alive ? 1 : 0);
		} finally {
			child.kill("SIGKILL");
			await child.exited;
			for (const [key, value] of Object.entries(saved)) {
				if (value === undefined) delete process.env[key];
				else process.env[key] = value;
			}
			clearPackageConfigCache();
		}
	}, 15_000);
}
