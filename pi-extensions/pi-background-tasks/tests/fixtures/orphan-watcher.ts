import type { ManagedTask } from "../../extensions/types.js";
import { fakeIdent, fakeTask } from "./lifecycle.js";

export function orphanTask(overrides: Partial<ManagedTask> = {}): ManagedTask {
	const pid = overrides.pid ?? 2409160;
	return fakeTask({ pid, procIdent: fakeIdent(pid), restored: true, ...overrides });
}
