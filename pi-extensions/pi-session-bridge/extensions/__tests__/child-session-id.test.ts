// A child Pi pane spawned by
// pi-agents-tmux should advertise a UNIQUE session id derived from
// PI_BRIDGE_PARENT_SESSION_ID + PI_BRIDGE_CHILD_ROLE so pi-bridge state
// --session <id> matches only one instance.

import { describe, expect, test } from "bun:test";

import {
	CHILD_ROLE_ENV,
	PARENT_SESSION_ENV,
	resolveSessionId,
} from "../child-session-id.js";

describe("resolveSessionId (kendex#60)", () => {
	test("no PI_BRIDGE_PARENT_SESSION_ID -> returns default unchanged", () => {
		const result = resolveSessionId({ defaultId: "abc-123", env: {} as NodeJS.ProcessEnv, pid: 42 });
		expect(result.synthesized).toBe(false);
		expect(result.sessionId).toBe("abc-123");
		expect(result.parentSessionId).toBeUndefined();
		expect(result.childRole).toBeUndefined();
	});

	test("PI_BRIDGE_PARENT_SESSION_ID set -> synthesizes <parent>:c<pid>", () => {
		const result = resolveSessionId({
			defaultId: "ignored-parent-id",
			env: { [PARENT_SESSION_ENV]: "parent-xyz", [CHILD_ROLE_ENV]: "subagent" } as any,
			pid: 4242,
		});
		expect(result.synthesized).toBe(true);
		expect(result.sessionId).toBe("parent-xyz:c4242");
		expect(result.parentSessionId).toBe("parent-xyz");
		expect(result.childRole).toBe("subagent");
	});

	test("child role omitted -> sessionId synthesized but childRole undefined", () => {
		const result = resolveSessionId({
			env: { [PARENT_SESSION_ENV]: "p1" } as any,
			pid: 7,
		});
		expect(result.synthesized).toBe(true);
		expect(result.sessionId).toBe("p1:c7");
		expect(result.parentSessionId).toBe("p1");
		expect(result.childRole).toBeUndefined();
	});

	test("whitespace-only parent id treated as unset", () => {
		const result = resolveSessionId({
			defaultId: "default",
			env: { [PARENT_SESSION_ENV]: "   " } as any,
			pid: 99,
		});
		expect(result.synthesized).toBe(false);
		expect(result.sessionId).toBe("default");
	});

	test("pid defaults to process.pid when not provided", () => {
		const result = resolveSessionId({ env: { [PARENT_SESSION_ENV]: "parent" } as any });
		expect(result.synthesized).toBe(true);
		expect(result.sessionId).toBe(`parent:c${process.pid}`);
	});

	test("env defaults to process.env when not provided", () => {
		const result = resolveSessionId({ defaultId: "fallback" });
		// No parent env set in this test runner -> default unchanged.
		expect(result.synthesized).toBe(false);
		expect(result.sessionId).toBe("fallback");
	});

	test("defaultId may be undefined; no synthesis still returns undefined", () => {
		const result = resolveSessionId({ env: {} as NodeJS.ProcessEnv });
		expect(result.synthesized).toBe(false);
		expect(result.sessionId).toBeUndefined();
	});
});
