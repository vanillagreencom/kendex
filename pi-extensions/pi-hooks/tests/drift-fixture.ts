import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/** Fake kendex that records argv, prints FAKE_OUT on stderr, exits FAKE_RC. */
function fakekendex(root: string): { binary: string; argsLog: string } {
	const binary = join(root, "kendex");
	const argsLog = join(root, "args.log");
	writeFileSync(
		binary,
		`#!/usr/bin/env bash
printf '%s\\n' "$*" >>"${argsLog}"
if [ -n "\${FAKE_OUT:-}" ]; then printf '%s\\n' "$FAKE_OUT" >&2; fi
exit "\${FAKE_RC:-0}"
`,
	);
	chmodSync(binary, 0o755);
	return { binary, argsLog };
}

export async function withFake<T>(rc: string, out: string, run: (paths: { binary: string; argsLog: string; root: string }) => Promise<T>): Promise<T> {
	const root = mkdtempSync(join(tmpdir(), "pi-hooks-drift-"));
	const paths = fakekendex(root);
	const oldRc = process.env.FAKE_RC;
	const oldOut = process.env.FAKE_OUT;
	process.env.FAKE_RC = rc;
	process.env.FAKE_OUT = out;
	try {
		return await run({ ...paths, root });
	} finally {
		if (oldRc === undefined) delete process.env.FAKE_RC;
		else process.env.FAKE_RC = oldRc;
		if (oldOut === undefined) delete process.env.FAKE_OUT;
		else process.env.FAKE_OUT = oldOut;
		rmSync(root, { recursive: true, force: true });
	}
}

