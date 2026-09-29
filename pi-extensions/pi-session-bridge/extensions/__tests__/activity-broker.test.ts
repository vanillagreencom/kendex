import { afterEach, beforeEach, describe, expect, setSystemTime, test } from "bun:test";

import {
	ACTIVITY_RECENT_MAX_AGE_MS,
	ACTIVITY_RECENT_MAX_CHARS,
	getPiActivityBroker,
	installPiActivityBridgePublisher,
	publishPiActivity,
	type PiActivityEvent,
} from "../activity-broker.js";

const BROKER_SYMBOL = Symbol.for("kendex.pi.activity");

function event(overrides: Partial<PiActivityEvent> = {}): PiActivityEvent {
	return {
		importance: "normal",
		severity: "info",
		source: "pi-session",
		summary: "activity event",
		type: "pi.session.event",
		...overrides,
	};
}

beforeEach(() => {
	delete (globalThis as unknown as Record<PropertyKey, unknown>)[BROKER_SYMBOL];
});

afterEach(() => setSystemTime());

describe("Pi activity broker", () => {
	test("publish and subscribe round-trip", () => {
		const broker = getPiActivityBroker();
		const seen: PiActivityEvent[] = [];
		const unsubscribe = broker.subscribe((item) => seen.push(item));
		broker.publish(event({ refs: { agent: "rust" }, type: "agent.spawned" }));
		unsubscribe();
		broker.publish(event({ type: "agent.ignored" }));

		expect(seen).toHaveLength(1);
		expect(seen[0]).toMatchObject({ refs: { agent: "rust" }, source: "pi-session", type: "agent.spawned" });
		expect(typeof seen[0]?.ts).toBe("string");
	});

	test("ring buffer caps at 100 events", () => {
		const broker = getPiActivityBroker();
		for (let index = 0; index < 105; index += 1) {
			broker.publish(event({ summary: `event ${index}`, type: `pi.event.${index}` }));
		}

		const recent = broker.recent(200);
		expect(recent).toHaveLength(100);
		expect(recent[0]?.type).toBe("pi.event.104");
		expect(recent.at(-1)?.type).toBe("pi.event.5");
	});

	test("the recent list holds at most ACTIVITY_RECENT_MAX_CHARS of events, newest kept", () => {
		const broker = getPiActivityBroker();
		const body = "b".repeat(Math.ceil(ACTIVITY_RECENT_MAX_CHARS / 10));
		for (let index = 0; index < 30; index += 1) broker.publish(event({ body, type: `pi.event.${index}` }));
		const recent = broker.recent(200);
		expect(JSON.stringify(recent).length).toBeLessThanOrEqual(ACTIVITY_RECENT_MAX_CHARS);
		expect(recent[0]?.type).toBe("pi.event.29");
		expect(recent.length).toBeLessThan(30);
	});

	test("an event older than ACTIVITY_RECENT_MAX_AGE_MS leaves the recent list", () => {
		const broker = getPiActivityBroker();
		setSystemTime(new Date("2026-01-01T00:00:00Z"));
		broker.publish(event({ type: "pi.event.old" }));
		setSystemTime(new Date(Date.parse("2026-01-01T00:00:00Z") + ACTIVITY_RECENT_MAX_AGE_MS + 1));
		broker.publish(event({ type: "pi.event.new" }));
		// The publish itself drops the expired event; nothing has to read the list.
		expect((broker as unknown as { _events: PiActivityEvent[] })._events.map((item) => item.type)).toEqual(["pi.event.new"]);
		expect(broker.recent(10).map((item) => item.type)).toEqual(["pi.event.new"]);
		setSystemTime(new Date(Date.parse("2026-01-01T00:00:00Z") + 2 * ACTIVITY_RECENT_MAX_AGE_MS + 2));
		expect(broker.recent(10)).toEqual([]);
	});

	test("recent returns newest first with requested limit", () => {
		const broker = getPiActivityBroker();
		broker.publish(event({ type: "pi.event.1" }));
		broker.publish(event({ type: "pi.event.2" }));
		broker.publish(event({ type: "pi.event.3" }));

		expect(broker.recent(2).map((item) => item.type)).toEqual(["pi.event.3", "pi.event.2"]);
	});

	test("bad listener does not break other listeners or bridge publisher", () => {
		const broker = getPiActivityBroker();
		const seen: string[] = [];
		const streamed: PiActivityEvent[] = [];
		broker.subscribe(() => { throw new Error("boom"); });
		broker.subscribe((item) => seen.push(item.type));
		installPiActivityBridgePublisher("test", (item) => streamed.push(item));

		publishPiActivity(event({ type: "pi.event.good" }));

		expect(seen).toEqual(["pi.event.good"]);
		expect(streamed.map((item) => item.type)).toEqual(["pi.event.good"]);
	});

	test("bridge publisher failures warn once per event type and error class", () => {
		const originalWarn = console.warn;
		const warnings: unknown[][] = [];
		console.warn = (...args: unknown[]) => { warnings.push(args); };
		try {
			const broker = getPiActivityBroker();
			installPiActivityBridgePublisher("failing", () => { throw new TypeError("socket closed"); });

			broker.publish(event({ source: "pi-agents", type: "agent.task_completed" }));
			broker.publish(event({ source: "pi-agents", type: "agent.task_completed" }));
			broker.publish(event({ source: "pi-agents", type: "agent.task_failed" }));

			expect(warnings).toHaveLength(2);
			expect(warnings.map((warning) => String(warning[0]).split("\n")[0])).toEqual([
				"publisher_failure=agent.task_completed source=pi-agents error=TypeError",
				"publisher_failure=agent.task_failed source=pi-agents error=TypeError",
			]);
		} finally {
			console.warn = originalWarn;
		}
	});

	test("recent filters malformed internal entries", () => {
		const broker = getPiActivityBroker();
		broker.publish(event({ type: "pi.event.valid1" }));
		(broker as unknown as { _events: unknown[] })._events.push({ source: "pi-session", type: "pi.event.malformed" });
		broker.publish(event({ type: "pi.event.valid2" }));

		expect(broker.recent(10).map((item) => item.type)).toEqual(["pi.event.valid2", "pi.event.valid1"]);
	});
});
