import { afterEach, beforeEach, expect, setSystemTime, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, rmSync, utimesSync } from "node:fs";
import { dirname, join } from "node:path";
import outputPolicy from "../extensions/output-policy.ts";
import { createFakePi, fakeCtx, withArtifactStorage } from "./fixtures.ts";

const now = 1_800_000_000_000;
const olderThanFiveDays = new Date(now - 6 * 24 * 60 * 60 * 1000);
beforeEach(() => setSystemTime(now));
afterEach(() => setSystemTime());

for (const storage of ["user", "temporary"] as const) {
	for (const state of ["gone", "old", "fresh"] as const) {
		test(`${storage} saved output: session_start prunes ${state} lanes or files`, async () => {
			await withArtifactStorage(storage, async (cwd) => {
				const laneCwd = join(cwd, "worktree");
				mkdirSync(laneCwd);
				const ctx = fakeCtx(laneCwd);
				const fake = createFakePi();
				outputPolicy(fake.pi);
				const text = "saved full output\n".repeat(5_000);
				const result = await fake.fire("tool_result", {
					content: [{ type: "text", text }], details: {}, input: {}, toolCallId: "retention", toolName: "grep",
				}, ctx);
				const artifact = result!.details.kendexOutputPolicy[0].artifactPath!;
				const lane = dirname(artifact);
				const expectedRoot = storage === "user"
					? join(cwd, "agent", "kendex", "sessions", ctx.sessionManager.getSessionId(), "pi-output-policy", "artifacts")
					: join(cwd, "temporary", "pi-output-policy", ctx.sessionManager.getSessionId());
				expect(lane).toBe(expectedRoot);
				expect(readFileSync(artifact, "utf8")).toBe(text);
				expect(readFileSync(join(lane, ".lane-cwd"), "utf8")).toBe(laneCwd);
				// The filesystem clock is real even when Date.now is injected.
				utimesSync(join(lane, ".lane-cwd"), new Date(now), new Date(now));
				const modified = state === "old" ? olderThanFiveDays : new Date(now);
				utimesSync(artifact, modified, modified);
				if (state === "gone") rmSync(laneCwd, { recursive: true });
				// A different session must clean earlier lanes, not just its own directory.
				await fake.fire("session_start", { type: "session_start" }, fakeCtx(cwd));
				expect({ lane: existsSync(lane), artifact: existsSync(artifact) }).toEqual({ lane: state !== "gone", artifact: state === "fresh" });
			});
		});
	}
}