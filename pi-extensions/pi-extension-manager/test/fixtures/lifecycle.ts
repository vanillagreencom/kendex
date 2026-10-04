import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const [source, root] = process.argv.slice(2);
assert(source && root);
const cwd = join(root, "project");
for (const dir of [join(root, "agent"), join(cwd, ".pi")]) {
	mkdirSync(dir, { recursive: true });
	writeFileSync(join(dir, "settings.json"), "{}");
}
const { default: extensionManager } = await import(join(source, "extension-manager.ts"));
const { inventorySession, sessionWork } = await import(join(source, "manager/inventory.ts"));
type Handler = (event: unknown, ctx: ExtensionContext) => Promise<void>;
const events = new Map<string, Handler[]>();
const api = {
	registerCommand() {}, registerShortcut() {},
	events: { on() { return () => {}; } },
	on(name: string, handler: Handler) { events.set(name, [...(events.get(name) ?? []), handler]); },
} as unknown as ExtensionAPI;
await extensionManager(api);
const ctx = { cwd, hasUI: false, isProjectTrusted: () => true } as ExtensionContext;
for (const name of ["session_start", "session_shutdown"]) assert(events.has(name), `lifecycle-registration: ${name}`);
for (const handler of events.get("session_start")!) await handler({}, ctx);
assert.equal(inventorySession(api).inventory, undefined, "lifecycle-headless: inventory");
ctx.hasUI = true;
for (const handler of events.get("session_start")!) await handler({}, ctx);
assert(inventorySession(api).inventory, "lifecycle-ui: inventory");
const session = inventorySession(api);
assert.equal(session.controller.signal.aborted, false);
// Pi's dispose awaits each handler in turn before it exits, so the shutdown
// must stay pending while the session's work runs.
let finishWork!: () => void;
void sessionWork(api, () => new Promise<void>((resolve) => { finishWork = resolve; }));
let shutdownSettled = false;
const shutdown = (async () => { for (const handler of events.get("session_shutdown")!) await handler({}, ctx); })().then(() => { shutdownSettled = true; });
await new Promise((resolve) => setImmediate(resolve));
assert.equal(shutdownSettled, false, "lifecycle-shutdown-wait: settled before the session's work");
finishWork();
await shutdown;
assert.equal(session.controller.signal.aborted, true, "lifecycle-shutdown: signal");
assert.equal(inventorySession(api).inventory, undefined, "lifecycle-shutdown: inventory");
for (const handler of events.get("session_shutdown")!) await handler({}, ctx);
assert.equal(inventorySession(api).inventory, undefined, "lifecycle-shutdown: repeated inventory");
