import { expect, test } from "bun:test";
import { CHILD_ROLE_ENV, PARENT_SESSION_ENV, resolveSessionId } from "../child-session-id.js";

for (const row of [
	{ name: "unset parent preserves default", defaultId: "abc-123", env: {}, pid: 42, expected: { synthesized: false, sessionId: "abc-123", parentSessionId: undefined, childRole: undefined } },
	{ name: "parent and role synthesize child identity", defaultId: "ignored-parent-id", env: { [PARENT_SESSION_ENV]: "parent-xyz", [CHILD_ROLE_ENV]: "subagent" }, pid: 4242, expected: { synthesized: true, sessionId: "parent-xyz:c4242", parentSessionId: "parent-xyz", childRole: "subagent" } },
	{ name: "omitted role", defaultId: undefined, env: { [PARENT_SESSION_ENV]: "p1" }, pid: 7, expected: { synthesized: true, sessionId: "p1:c7", parentSessionId: "p1", childRole: undefined } },
	{ name: "whitespace parent", defaultId: "default", env: { [PARENT_SESSION_ENV]: "   " }, pid: 99, expected: { synthesized: false, sessionId: "default", parentSessionId: undefined, childRole: undefined } },
	{ name: "process pid default", defaultId: undefined, env: { [PARENT_SESSION_ENV]: "parent" }, pid: undefined, expected: { synthesized: true, sessionId: `parent:c${process.pid}`, parentSessionId: "parent", childRole: undefined } },
	{ name: "missing default identity", defaultId: undefined, env: {}, pid: undefined, expected: { synthesized: false, sessionId: undefined, parentSessionId: undefined, childRole: undefined } },
]) {
	test(row.name, () => expect(resolveSessionId({ defaultId: row.defaultId, env: row.env, pid: row.pid })).toEqual(row.expected));
}

test("omitted env reads process environment", () => {
	const parent = process.env[PARENT_SESSION_ENV];
	const role = process.env[CHILD_ROLE_ENV];
	try {
		delete process.env[PARENT_SESSION_ENV];
		delete process.env[CHILD_ROLE_ENV];
		expect(resolveSessionId({ defaultId: "fallback" })).toEqual({ synthesized: false, sessionId: "fallback", parentSessionId: undefined, childRole: undefined });
	} finally {
		if (parent === undefined) delete process.env[PARENT_SESSION_ENV]; else process.env[PARENT_SESSION_ENV] = parent;
		if (role === undefined) delete process.env[CHILD_ROLE_ENV]; else process.env[CHILD_ROLE_ENV] = role;
	}
});
