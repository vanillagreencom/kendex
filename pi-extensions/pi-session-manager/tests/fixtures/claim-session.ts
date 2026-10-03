// Another lane's Pi: claims one session through the extension's own handler,
// prints `claimed`, then stays alive until the test kills it.
import { installSessionClaim } from "../../extensions/live-sessions.ts";

const [cwd, sessionFile, sessionId] = process.argv.slice(2);
const handlers = new Map<string, (event: unknown, ctx: unknown) => Promise<void>>();
installSessionClaim({ on: (name: string, handler: (event: unknown, ctx: unknown) => Promise<void>) => void handlers.set(name, handler) } as never);
await handlers.get("session_start")!({ type: "session_start", reason: "startup" }, {
	cwd,
	sessionManager: { getSessionFile: () => sessionFile, getSessionId: () => sessionId },
});
process.stdout.write("claimed\n");
setInterval(() => {}, 60_000);
