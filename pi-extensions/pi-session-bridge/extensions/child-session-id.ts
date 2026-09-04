// Synthesize a unique session id for spawned
// subagent Pi panes.
//
// Upstream pi-coding-agent has a bug where a child Pi process spawned
// from a parent Pi pane inherits the parent's session id. The
// downstream effect is `pi-bridge state --session <id>` failing with
// "Multiple matching pi session bridges" and orchestrators that key on
// session id silently breaking.
//
// kendex-side fix: pi-agents-tmux's subagent runner sets
// PI_BRIDGE_PARENT_SESSION_ID + PI_BRIDGE_CHILD_ROLE in the child's
// env when launching it. On startup, the bridge reads those env vars
// and synthesizes `<parent>:c<child-pid>` as the reported session id
// instead of inheriting the parent's. The original parent id is
// preserved alongside under `parent_session_id` for explicit parent-
// child tracking.

export const PARENT_SESSION_ENV = "PI_BRIDGE_PARENT_SESSION_ID";
export const CHILD_ROLE_ENV = "PI_BRIDGE_CHILD_ROLE";

export interface ResolveSessionIdInput {
	defaultId?: string;
	env?: NodeJS.ProcessEnv;
	pid?: number;
}

export interface ResolveSessionIdResult {
	sessionId?: string;
	parentSessionId?: string;
	childRole?: string;
	synthesized: boolean;
}

function trimmedEnv(env: NodeJS.ProcessEnv | undefined, key: string): string {
	const raw = env?.[key];
	if (typeof raw !== "string") return "";
	return raw.trim();
}

/**
 * Returns the session id the bridge should advertise.
 *
 * - When `PI_BRIDGE_PARENT_SESSION_ID` is non-empty, the result is
 *   `<parent>:c<pid>` and `parentSessionId` records the original value
 *   so consumers can still walk the parent-child relationship.
 * - Otherwise the input `defaultId` (from pi-core's sessionManager) is
 *   returned unchanged.
 *
 * Pure / side-effect free so the bridge can call it on every state
 * report and tests can drive it deterministically.
 */
export function resolveSessionId(input: ResolveSessionIdInput = {}): ResolveSessionIdResult {
	const env = input.env ?? process.env;
	const parent = trimmedEnv(env, PARENT_SESSION_ENV);
	const childRole = trimmedEnv(env, CHILD_ROLE_ENV);
	if (!parent) {
		return { sessionId: input.defaultId, synthesized: false };
	}
	const pid = input.pid ?? process.pid;
	const sessionId = `${parent}:c${pid}`;
	return {
		sessionId,
		parentSessionId: parent,
		childRole: childRole || undefined,
		synthesized: true,
	};
}
