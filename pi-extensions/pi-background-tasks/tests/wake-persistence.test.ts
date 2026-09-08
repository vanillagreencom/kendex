import { expect, test } from "bun:test";
import { createPersistence } from "../extensions/persistence.js";
import type { PersistenceDeps, PersistencePayload } from "../extensions/persistence.js";
import { taskSnapshot } from "../extensions/snapshot.js";
import { scheduleTaskWake, sendTaskWake } from "../extensions/wake-events.js";
import { fakeTask } from "./fixtures/lifecycle.js";
import { sendDeps } from "./fixtures/wake.js";

test("appended snapshot retains delivered wake metadata", () => {
	const task = fakeTask({ id: "bg-7", status: "running", notifyOnOutput: true, lastOutputAt: 1_555 });
	const pending = scheduleTaskWake(task, "output", 1_555);
	const { deps } = sendDeps();
	const sent = sendTaskWake(deps, "output", task, { eventAt: pending.eventAt, sequence: pending.sequence, newOutputTail: "ready\n" });
	const appended: { customType: string; payload: PersistencePayload }[] = [];
	const pi = { appendEntry: (customType: string, payload: unknown) => appended.push({ customType, payload: payload as PersistencePayload }) };
	// A null context appends session data without writing a user sidecar.
	const persistence = createPersistence({ customType: "pi-bg-state", getActiveCtx: () => null,
		listSnapshots: () => [taskSnapshot(task)], pi: pi as PersistenceDeps["pi"] });
	const result = persistence.persistSnapshots();
	expect({ sent, appended: result.appendEntry, records: appended.map(({ customType, payload }) => ({
		customType, events: payload.tasks.map((snapshot) => snapshot.wakeEvents),
	})) }).toStrictEqual({ sent: true, appended: true, records: [{ customType: "pi-bg-state", events: [[{
		deliveredAt: 2_000, eventAt: 1_555, eventType: "output", sequence: 1, taskStatusAtEmit: "running",
	}]] }] });
});
